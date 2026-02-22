/*
* This file is part of the BTCCollider distribution (https://github.com/JeanLucPons/Kangaroo).
* Copyright (c) 2020 Jean Luc PONS.
*
* This program is free software: you can redistribute it and/or modify
* it under the terms of the GNU General Public License as published by
* the Free Software Foundation, version 3.
*
* This program is distributed in the hope that it will be useful, but
* WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
* General Public License for more details.
*
* You should have received a copy of the GNU General Public License
* along with this program. If not, see <http://www.gnu.org/licenses/>.
*/

#ifndef WIN64
#include <unistd.h>
#include <stdio.h>
#endif

#include "GPUEngine.h"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <inttypes.h>
#include <limits.h>
#include <string>
#include <sys/stat.h>
#include <vector>

#include "../Timer.h"

#define Point MacTypesPoint
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#undef Point

#include <mach-o/dyld.h>

using namespace std;

namespace {

// NOTE: This is the *algorithmic* group size (kangaroos per GPU thread), not Metal threads/group.
// CUDA backend defaults to GPU_GRP_SIZE (=128). Metal started with a conservative cap because
// larger per-thread arrays can balloon register/local-memory usage. We now compile the shader
// with the requested group size as a preprocessor macro, so allow up to GPU_GRP_SIZE.
constexpr int kMetalMaxGroupSize = GPU_GRP_SIZE;

struct KernelParams {
  uint32_t maxFound;
  uint32_t nbThreadPerGroup;
  uint32_t nbThreadGroup;
  uint32_t nbRun;
  uint32_t kSize;
  uint32_t gpuGroupSize;
  uint32_t profileMode;
  uint32_t paramPad;       // 显式 padding，确保 dpMask 在 C++ 和 Metal 端偏移一致
  uint64_t dpMask;
};

struct MathTestInput {
  uint64_t a[4];
  uint64_t b[4];
  uint64_t px[4];
  uint64_t py[4];
  uint64_t jx[4];
  uint64_t jy[4];
};

struct MathTestOutput {
  uint64_t mul[4];
  uint64_t sqr[4];
  uint64_t inv[4];
  uint64_t rx[4];
  uint64_t ry[4];
  uint32_t flags;
  uint32_t pad;
};

struct MetalContext {
  id<MTLDevice> device;
  id<MTLCommandQueue> queue;
  id<MTLComputePipelineState> pipeline;
  id<MTLComputePipelineState> pipelineMode1;
  id<MTLComputePipelineState> pipelineMode4;

  id<MTLBuffer> kangarooBuffer;
  id<MTLBuffer> outputBuffers[2];
  id<MTLBuffer> jumpDistBuffer;
  id<MTLBuffer> jumpXBuffer;
  id<MTLBuffer> jumpYBuffer;
  id<MTLBuffer> invProfileBuffer;

  uint32_t *outputWords[2];
  uint32_t *invProfileWords;

  id<MTLCommandBuffer> inflight;
  int inflightBufferIdx;
  int writeBufferIdx;

  bool profileEnabled;
  bool invProfileEnabled;
  bool blockWaitEnabled;
  uint64_t completedLaunches;
  double accumulatedGpuMs;
  double walkersPerLaunch;
  int waitTimeoutMs;
  uint64_t invCallsAccum;
  uint64_t invFallbackAccum;
  uint64_t invIterAccum;
  uint32_t invIterMax;
  uint64_t invFallbackIterLimitAccum;
  uint64_t invFallbackGcdAccum;
  uint64_t invFallbackNormNegAccum;
  uint64_t invFallbackNormPosAccum;
  int activeStateCacheMode;
  int requestedStateCacheMode;
  bool stateCacheModeExplicit;
  bool autoMode14Enabled;
  bool autoMode14Evaluated;

  MetalContext()
      : device(nil),
        queue(nil),
        pipeline(nil),
        pipelineMode1(nil),
        pipelineMode4(nil),
        kangarooBuffer(nil),
        jumpDistBuffer(nil),
        jumpXBuffer(nil),
        jumpYBuffer(nil),
        invProfileBuffer(nil),
        inflight(nil),
        inflightBufferIdx(-1),
        writeBufferIdx(0),
        profileEnabled(false),
        invProfileEnabled(false),
        blockWaitEnabled(false),
        completedLaunches(0),
        accumulatedGpuMs(0.0),
        walkersPerLaunch(0.0),
        waitTimeoutMs(3000),
        invCallsAccum(0),
        invFallbackAccum(0),
        invIterAccum(0),
        invIterMax(0),
        invFallbackIterLimitAccum(0),
        invFallbackGcdAccum(0),
        invFallbackNormNegAccum(0),
        invFallbackNormPosAccum(0),
        activeStateCacheMode(0),
        requestedStateCacheMode(0),
        stateCacheModeExplicit(false),
        autoMode14Enabled(false),
        autoMode14Evaluated(false) {
    outputBuffers[0] = nil;
    outputBuffers[1] = nil;
    outputWords[0] = nullptr;
    outputWords[1] = nullptr;
    invProfileWords = nullptr;
  }
};

bool FileExists(const string &path) {
  struct stat st;
  return stat(path.c_str(), &st) == 0;
}

bool IsEnvEnabled(const char *name) {
  const char *v = ::getenv(name);
  if(v == nullptr) {
    return false;
  }
  if(v[0] == '0' && v[1] == 0) {
    return false;
  }
  return true;
}

int GetEnvIntClamped(const char *name, int fallback, int minValue, int maxValue) {
  const char *v = ::getenv(name);
  if(v == nullptr || v[0] == 0) {
    return fallback;
  }

  char *end = nullptr;
  long parsed = strtol(v, &end, 10);
  if(end == v || *end != 0) {
    return fallback;
  }
  if(parsed < (long)minValue) {
    parsed = (long)minValue;
  }
  if(parsed > (long)maxValue) {
    parsed = (long)maxValue;
  }
  return (int)parsed;
}

int GetStateCacheMode() {
  // New knob (preferred):
  // 0=full cache, 1=no cache, 2=px cache, 3=d cache, 4=simd coop inv, 5=jacobian mixed proto.
  int mode = GetEnvIntClamped("KANGAROO_METAL_STATE_CACHE_MODE", -1, -1, 5);
  if(mode >= 0) {
    return mode;
  }

  // Backward compatibility:
  // - unset / 0 -> full cache
  // - 1 / any non-zero -> no cache
  // - 2 -> px cache (new intermediate mode)
  // - 3 -> d cache (new intermediate mode)
  // - 4 -> simd coop inversion prototype
  // - 5 -> jacobian mixed-coordinate prototype
  const char *legacy = ::getenv("KANGAROO_METAL_NO_STATE_CACHE");
  if(legacy == nullptr || legacy[0] == 0) {
    return 0;
  }
  if(legacy[0] == '0' && legacy[1] == 0) {
    return 0;
  }
  if(legacy[0] == '2' && legacy[1] == 0) {
    return 2;
  }
  if(legacy[0] == '3' && legacy[1] == 0) {
    return 3;
  }
  if(legacy[0] == '4' && legacy[1] == 0) {
    return 4;
  }
  if(legacy[0] == '5' && legacy[1] == 0) {
    return 5;
  }
  return 1;
}

bool HasExplicitStateCacheModeEnv() {
  const char *modern = ::getenv("KANGAROO_METAL_STATE_CACHE_MODE");
  if(modern != nullptr && modern[0] != 0) {
    return true;
  }
  const char *legacy = ::getenv("KANGAROO_METAL_NO_STATE_CACHE");
  if(legacy != nullptr && legacy[0] != 0) {
    return true;
  }
  return false;
}

bool IsMode4Eligible(int nbThreadPerGroup) {
  return (nbThreadPerGroup % 32) == 0 && nbThreadPerGroup <= 256;
}

const char *GetStateCacheKernelName(int mode) {
  switch(mode) {
  case 1:
    return "kangaroo_step_nocache";
  case 2:
    return "kangaroo_step_nocache_pxcache";
  case 3:
    return "kangaroo_step_nocache_dcache";
  case 4:
    return "kangaroo_step_simd_inv";
  case 5:
    return "kangaroo_step_jacobian_mixed";
  default:
    return "kangaroo_step";
  }
}

const char *GetStateCacheModeName(int mode) {
  switch(mode) {
  case 1:
    return "none";
  case 2:
    return "px";
  case 3:
    return "d";
  case 4:
    return "simd";
  case 5:
    return "jacobian";
  default:
    return "full";
  }
}

string GetExecutableDir() {
  char pathBuf[PATH_MAX];
  uint32_t size = sizeof(pathBuf);
  if(_NSGetExecutablePath(pathBuf, &size) != 0) {
    return ".";
  }

  string exePath(pathBuf);
  size_t slash = exePath.find_last_of('/');
  if(slash == string::npos) {
    return ".";
  }
  return exePath.substr(0, slash);
}

string ResolveShaderPath() {
  const char *envPath = ::getenv("KANGAROO_METAL_SHADER_PATH");
  if(envPath != nullptr && FileExists(envPath)) {
    return string(envPath);
  }

  const string exeDir = GetExecutableDir();
  const vector<string> candidates = {
      "GPU/KangarooMetal.metal",
      "./GPU/KangarooMetal.metal",
      exeDir + "/GPU/KangarooMetal.metal",
      exeDir + "/../GPU/KangarooMetal.metal",
      exeDir + "/../Kangaroo/GPU/KangarooMetal.metal",
  };

  for(const string &candidate : candidates) {
    if(FileExists(candidate)) {
      return candidate;
    }
  }

  return "";
}

id<MTLComputePipelineState> BuildPipeline(id<MTLDevice> device,
                                          const string &functionName,
                                          string &errorMsg,
                                          int gpuGroupSize,
                                          int nbRun) {
  @autoreleasepool {
    const string shaderPath = ResolveShaderPath();
    if(shaderPath.empty()) {
      errorMsg = "cannot find Metal shader file (expected GPU/KangarooMetal.metal)";
      return nil;
    }

    NSError *error = nil;
    NSString *path = [NSString stringWithUTF8String:shaderPath.c_str()];
    NSString *source =
        [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
    if(source == nil) {
      errorMsg = string("failed to load shader source ") + shaderPath;
      if(error != nil) {
        errorMsg += " (";
        errorMsg += [[error localizedDescription] UTF8String];
        errorMsg += ")";
      }
      return nil;
    }

	    MTLCompileOptions *options = [[MTLCompileOptions alloc] init];
#if defined(__MAC_15_0)
	    options.mathMode = MTLMathModeFast;
#else
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	    options.fastMathEnabled = YES;
#pragma clang diagnostic pop
#endif

	    // Optional shader toggles (kept env-driven so we can A/B test without editing .metal).
	    // Default values live in the shader source behind #ifndef guards.
	    NSMutableDictionary<NSString *, id> *macros = [NSMutableDictionary dictionary];
	    if(IsEnvEnabled("KANGAROO_METAL_NATIVE_WIDE_MUL")) {
	      macros[@"KANGAROO_METAL_USE_NATIVE_WIDE_MUL"] = @"1";
	    }
	    if(IsEnvEnabled("KANGAROO_METAL_UNSIGNED_MULHI")) {
	      macros[@"KANGAROO_METAL_USE_UNSIGNED_MULHI"] = @"1";
	    }
	    if(IsEnvEnabled("KANGAROO_METAL_ENABLE_REDUCEC_SPECIAL")) {
	      macros[@"KANGAROO_METAL_SPECIALIZE_REDUCEC"] = @"1";
	    }
	    if(IsEnvEnabled("KANGAROO_METAL_DISABLE_REDUCEC_SPECIAL")) {
	      macros[@"KANGAROO_METAL_SPECIALIZE_REDUCEC"] = @"0";
	    }

	    // Compile-time specialization knobs (reduce register pressure / enable unrolling).
	    // Keep them in sync with the host-side engine parameters.
	    macros[@"KANGAROO_METAL_GRP_SIZE"] = [NSString stringWithFormat:@"%d", gpuGroupSize];
	    macros[@"KANGAROO_METAL_NB_RUN"] = [NSString stringWithFormat:@"%d", nbRun];
	    if(IsEnvEnabled("KANGAROO_METAL_INV_PROFILE")) {
	      macros[@"KANGAROO_METAL_ENABLE_INV_PROFILE"] = @"1";
	    }
#ifdef USE_SYMMETRY
	    macros[@"KANGAROO_METAL_USE_SYMMETRY"] = @"1";
#endif
	    if([macros count] != 0) {
	      options.preprocessorMacros = macros;
	    }

	    id<MTLLibrary> lib = [device newLibraryWithSource:source options:options error:&error];
	    if(lib == nil) {
	      errorMsg = "failed to compile Metal shader";
      if(error != nil) {
        errorMsg += ": ";
        errorMsg += [[error localizedDescription] UTF8String];
      }
      return nil;
    }

    NSString *fn = [NSString stringWithUTF8String:functionName.c_str()];
    id<MTLFunction> func = [lib newFunctionWithName:fn];
    if(func == nil) {
      errorMsg = "Metal function not found: " + functionName;
      return nil;
    }

    id<MTLComputePipelineState> pipeline =
        [device newComputePipelineStateWithFunction:func error:&error];
    if(pipeline == nil) {
      errorMsg = "failed to build Metal compute pipeline for " + functionName;
      if(error != nil) {
        errorMsg += ": ";
        errorMsg += [[error localizedDescription] UTF8String];
      }
      return nil;
    }

    return pipeline;
  }
}

bool WaitForInflight(MetalContext *ctx, bool spinWait) {
  if(ctx == nullptr || ctx->inflight == nil) {
    return true;
  }

  if(spinWait || ctx->blockWaitEnabled) {
    [ctx->inflight waitUntilCompleted];
  } else {
    double t0 = Timer::get_tick();
    while(true) {
      MTLCommandBufferStatus status = [ctx->inflight status];
      if(status == MTLCommandBufferStatusCompleted) {
        break;
      }
      if(status == MTLCommandBufferStatusError) {
        break;
      }
      if(ctx->waitTimeoutMs > 0) {
        double elapsedMs = (Timer::get_tick() - t0) * 1000.0;
        if(elapsedMs >= (double)ctx->waitTimeoutMs) {
          printf("GPUEngine(Metal): command buffer timeout after %.0f ms\n", elapsedMs);
          ctx->inflight = nil;
          return false;
        }
      }
      Timer::SleepMillis(1);
    }
  }

  if([ctx->inflight status] != MTLCommandBufferStatusCompleted) {
    NSError *error = [ctx->inflight error];
    if(error != nil) {
      printf("GPUEngine(Metal): command buffer failed: %s\n",
             [[error localizedDescription] UTF8String]);
    } else {
      printf("GPUEngine(Metal): command buffer failed\n");
    }
    ctx->inflight = nil;
    return false;
  }

  ctx->completedLaunches++;

  if(ctx->invProfileEnabled && ctx->invProfileWords != nullptr) {
    uint32_t invCalls = ctx->invProfileWords[0];
    uint32_t invFallback = ctx->invProfileWords[1];
    uint32_t invIters = ctx->invProfileWords[2];
    uint32_t invIterMax = ctx->invProfileWords[3];
    uint32_t invFallbackIterLimit = ctx->invProfileWords[4];
    uint32_t invFallbackGcd = ctx->invProfileWords[5];
    uint32_t invFallbackNormNeg = ctx->invProfileWords[6];
    uint32_t invFallbackNormPos = ctx->invProfileWords[7];
    ctx->invCallsAccum += (uint64_t)invCalls;
    ctx->invFallbackAccum += (uint64_t)invFallback;
    ctx->invIterAccum += (uint64_t)invIters;
    ctx->invFallbackIterLimitAccum += (uint64_t)invFallbackIterLimit;
    ctx->invFallbackGcdAccum += (uint64_t)invFallbackGcd;
    ctx->invFallbackNormNegAccum += (uint64_t)invFallbackNormNeg;
    ctx->invFallbackNormPosAccum += (uint64_t)invFallbackNormPos;
    if(invIterMax > ctx->invIterMax) {
      ctx->invIterMax = invIterMax;
    }
  }

  if(ctx->profileEnabled) {
    double start = [ctx->inflight GPUStartTime];
    double end = [ctx->inflight GPUEndTime];
    if(end > start && start > 0.0) {
      ctx->accumulatedGpuMs += (end - start) * 1000.0;
    }
  }

  if((ctx->completedLaunches % 256ULL) == 0ULL) {
    if(ctx->profileEnabled) {
      double avg = ctx->accumulatedGpuMs / 256.0;
      double mKeyPerSec = 0.0;
      if(avg > 0.0 && ctx->walkersPerLaunch > 0.0) {
        mKeyPerSec = (ctx->walkersPerLaunch / (avg / 1000.0)) / 1000000.0;
      }
      printf("GPUEngine(Metal): avg %.3f ms/kernel, %.3f MKey/s over last 256 launches\n",
             avg,
             mKeyPerSec);
      ctx->accumulatedGpuMs = 0.0;
    }

    if(ctx->invProfileEnabled) {
      double avgInvIter = 0.0;
      double fallbackPct = 0.0;
      double reasonIterLimitPct = 0.0;
      double reasonGcdPct = 0.0;
      double reasonNormNegPct = 0.0;
      double reasonNormPosPct = 0.0;
      if(ctx->invCallsAccum > 0ULL) {
        avgInvIter = (double)ctx->invIterAccum / (double)ctx->invCallsAccum;
        fallbackPct = 100.0 * (double)ctx->invFallbackAccum / (double)ctx->invCallsAccum;
        reasonIterLimitPct =
            100.0 * (double)ctx->invFallbackIterLimitAccum / (double)ctx->invCallsAccum;
        reasonGcdPct = 100.0 * (double)ctx->invFallbackGcdAccum / (double)ctx->invCallsAccum;
        reasonNormNegPct =
            100.0 * (double)ctx->invFallbackNormNegAccum / (double)ctx->invCallsAccum;
        reasonNormPosPct =
            100.0 * (double)ctx->invFallbackNormPosAccum / (double)ctx->invCallsAccum;
      }
      printf("GPUEngine(Metal): mod_inv stats calls=%llu avgIter=%.2f fallback=%.4f%% maxIter=%u reasons{iter=%.4f%% gcd=%.4f%% normNeg=%.4f%% normPos=%.4f%%} (last 256 launches)\n",
             (unsigned long long)ctx->invCallsAccum,
             avgInvIter,
             fallbackPct,
             ctx->invIterMax,
             reasonIterLimitPct,
             reasonGcdPct,
             reasonNormNegPct,
             reasonNormPosPct);
      ctx->invCallsAccum = 0ULL;
      ctx->invFallbackAccum = 0ULL;
      ctx->invIterAccum = 0ULL;
      ctx->invIterMax = 0U;
      ctx->invFallbackIterLimitAccum = 0ULL;
      ctx->invFallbackGcdAccum = 0ULL;
      ctx->invFallbackNormNegAccum = 0ULL;
      ctx->invFallbackNormPosAccum = 0ULL;
    }
  }

  ctx->inflight = nil;
  return true;
}

void CopyIntTo4(const Int &src, uint64_t dst[4]) {
  dst[0] = src.bits64[0];
  dst[1] = src.bits64[1];
  dst[2] = src.bits64[2];
  dst[3] = src.bits64[3];
}

bool Eq4(const uint64_t a[4], const uint64_t b[4]) {
  return a[0] == b[0] && a[1] == b[1] && a[2] == b[2] && a[3] == b[3];
}

void Print4(const char *name, const uint64_t v[4]) {
  printf("%s=%016" PRIx64 " %016" PRIx64 " %016" PRIx64 " %016" PRIx64 "\n",
         name,
         v[3],
         v[2],
         v[1],
         v[0]);
}

}  // namespace

void GPUEngine::SetWildOffset(Int *offset) { wildOffset.Set(offset); }

GPUEngine::GPUEngine(int nbThreadGroup, int nbThreadPerGroup, int gpuId, uint32_t maxFound) {

  this->nbThreadPerGroup = nbThreadPerGroup;
  this->nbThread = nbThreadGroup * nbThreadPerGroup;
  this->maxFound = maxFound;
  this->outputSize = (maxFound * ITEM_SIZE + 4);
  this->dpMask = 0;
  this->runCount = GetEnvIntClamped("KANGAROO_METAL_NB_RUN", 4, 1, NB_RUN);
  this->groupSize =
      GetEnvIntClamped("KANGAROO_METAL_GRP_SIZE", 16, 1, std::min<int>(GPU_GRP_SIZE, kMetalMaxGroupSize));

  initialised = false;
  lostWarning = false;
  backendContext = nullptr;

  inputKangaroo = nullptr;
  inputKangarooPinned = nullptr;
  outputItem = nullptr;
  outputItemPinned = nullptr;
  jumpPinned = nullptr;

  kangarooSize = nbThread * groupSize * KSIZE * 8;
  kangarooSizePinned = nbThreadPerGroup * groupSize * KSIZE * 8;
  jumpSize = NB_JUMP * 8 * 4;

  MetalContext *ctx = new MetalContext();
  backendContext = reinterpret_cast<void *>(ctx);

  @autoreleasepool {
    NSArray<id<MTLDevice>> *devices = MTLCopyAllDevices();
    if(devices == nil || [devices count] == 0) {
      printf("GPUEngine(Metal): no Metal device available\n");
      return;
    }

    if(gpuId < 0 || (NSUInteger)gpuId >= [devices count]) {
      printf("GPUEngine(Metal): invalid gpuId %d\n", gpuId);
      return;
    }

    ctx->device = [devices objectAtIndex:(NSUInteger)gpuId];
    ctx->queue = [ctx->device newCommandQueue];

    if(ctx->queue == nil) {
      printf("GPUEngine(Metal): failed to create command queue\n");
      return;
    }

    int stateCacheMode = GetStateCacheMode();
    const bool explicitStateMode = HasExplicitStateCacheModeEnv();
    ctx->requestedStateCacheMode = stateCacheMode;
    ctx->stateCacheModeExplicit = explicitStateMode;

    bool autoMode14 = (!explicitStateMode && !IsEnvEnabled("KANGAROO_METAL_DISABLE_AUTO_MODE14"));

    if(stateCacheMode == 4 && !IsMode4Eligible(nbThreadPerGroup)) {
      printf("GPUEngine(Metal): stateCache=simd requires threads/group to be a multiple of 32 and <= 256, fallback to stateCache=none\n");
      stateCacheMode = 1;
    }
#ifdef USE_SYMMETRY
    if(stateCacheMode == 5) {
      printf("GPUEngine(Metal): stateCache=jacobian is not symmetry-aware yet, fallback to stateCache=none\n");
      stateCacheMode = 1;
    }
#endif
    if(autoMode14 && !IsMode4Eligible(nbThreadPerGroup)) {
      printf("GPUEngine(Metal): auto stateCache(1/4) disabled because threads/group=%d is incompatible with mode=4\n",
             nbThreadPerGroup);
      autoMode14 = false;
    }

    auto pipelineFits = [&](id<MTLComputePipelineState> p, const char *name) -> bool {
      NSUInteger maxThreads = [p maxTotalThreadsPerThreadgroup];
      if((NSUInteger)nbThreadPerGroup > maxThreads) {
        printf("GPUEngine(Metal): threadgroup size %d exceeds hardware limit %lu for stateCache=%s\n",
               nbThreadPerGroup,
               (unsigned long)maxThreads,
               name);
        return false;
      }
      return true;
    };

    if(autoMode14) {
      string pipelineErrMode1;
      ctx->pipelineMode1 =
          BuildPipeline(ctx->device, GetStateCacheKernelName(1), pipelineErrMode1, groupSize, runCount);
      if(ctx->pipelineMode1 == nil) {
        printf("GPUEngine(Metal): %s\n", pipelineErrMode1.c_str());
        return;
      }

      string pipelineErrMode4;
      ctx->pipelineMode4 =
          BuildPipeline(ctx->device, GetStateCacheKernelName(4), pipelineErrMode4, groupSize, runCount);
      if(ctx->pipelineMode4 == nil) {
        printf("GPUEngine(Metal): %s\n", pipelineErrMode4.c_str());
        printf("GPUEngine(Metal): auto stateCache(1/4) disabled, fallback to stateCache=none\n");
        autoMode14 = false;
      } else if(!pipelineFits(ctx->pipelineMode1, "none") || !pipelineFits(ctx->pipelineMode4, "simd")) {
        return;
      }

      if(autoMode14) {
        ctx->pipeline = ctx->pipelineMode1;
        ctx->activeStateCacheMode = 1;
        ctx->autoMode14Enabled = true;
        ctx->autoMode14Evaluated = false;
      }
    }

    if(!autoMode14) {
      if(!explicitStateMode && stateCacheMode == 0) {
        stateCacheMode = 1;
      }
      string pipelineErr;
      const string kernelFn = GetStateCacheKernelName(stateCacheMode);
      ctx->pipeline = BuildPipeline(ctx->device, kernelFn, pipelineErr, groupSize, runCount);
      if(ctx->pipeline == nil) {
        printf("GPUEngine(Metal): %s\n", pipelineErr.c_str());
        return;
      }
      if(!pipelineFits(ctx->pipeline, GetStateCacheModeName(stateCacheMode))) {
        return;
      }
      ctx->activeStateCacheMode = stateCacheMode;
      ctx->autoMode14Enabled = false;
      ctx->autoMode14Evaluated = true;
      if(stateCacheMode == 1) {
        ctx->pipelineMode1 = ctx->pipeline;
      } else if(stateCacheMode == 4) {
        ctx->pipelineMode4 = ctx->pipeline;
      }
    }

    ctx->kangarooBuffer =
        [ctx->device newBufferWithLength:kangarooSize options:MTLResourceStorageModeShared];
    ctx->outputBuffers[0] =
        [ctx->device newBufferWithLength:outputSize options:MTLResourceStorageModeShared];
    ctx->outputBuffers[1] =
        [ctx->device newBufferWithLength:outputSize options:MTLResourceStorageModeShared];

    ctx->jumpDistBuffer =
        [ctx->device newBufferWithLength:(NB_JUMP * 2 * sizeof(uint64_t))
                                 options:MTLResourceStorageModeShared];
    ctx->jumpXBuffer = [ctx->device newBufferWithLength:(NB_JUMP * 4 * sizeof(uint64_t))
                                                 options:MTLResourceStorageModeShared];
    ctx->jumpYBuffer = [ctx->device newBufferWithLength:(NB_JUMP * 4 * sizeof(uint64_t))
                                                 options:MTLResourceStorageModeShared];
    ctx->invProfileBuffer =
        [ctx->device newBufferWithLength:(8 * sizeof(uint32_t)) options:MTLResourceStorageModeShared];

    if(ctx->kangarooBuffer == nil || ctx->outputBuffers[0] == nil ||
       ctx->outputBuffers[1] == nil || ctx->jumpDistBuffer == nil ||
       ctx->jumpXBuffer == nil || ctx->jumpYBuffer == nil || ctx->invProfileBuffer == nil) {
      printf("GPUEngine(Metal): buffer allocation failed\n");
      return;
    }

    inputKangaroo = reinterpret_cast<uint64_t *>([ctx->kangarooBuffer contents]);
    ctx->outputWords[0] = reinterpret_cast<uint32_t *>([ctx->outputBuffers[0] contents]);
    ctx->outputWords[1] = reinterpret_cast<uint32_t *>([ctx->outputBuffers[1] contents]);
    ctx->invProfileWords = reinterpret_cast<uint32_t *>([ctx->invProfileBuffer contents]);
    outputItem = ctx->outputWords[0];

    inputKangarooPinned = reinterpret_cast<uint64_t *>(::malloc(kangarooSizePinned));
    outputItemPinned = reinterpret_cast<uint32_t *>(::malloc(outputSize));
    jumpPinned = reinterpret_cast<uint64_t *>(::malloc(jumpSize));

    if(inputKangarooPinned == nullptr || outputItemPinned == nullptr || jumpPinned == nullptr) {
      printf("GPUEngine(Metal): host staging allocation failed\n");
      return;
    }

    memset(inputKangaroo, 0, kangarooSize);
    memset(ctx->outputWords[0], 0, outputSize);
    memset(ctx->outputWords[1], 0, outputSize);
    memset(ctx->invProfileWords, 0, 8 * sizeof(uint32_t));

    ctx->profileEnabled = IsEnvEnabled("KANGAROO_METAL_PROFILE");
    ctx->invProfileEnabled = IsEnvEnabled("KANGAROO_METAL_INV_PROFILE");
    ctx->blockWaitEnabled = IsEnvEnabled("KANGAROO_METAL_BLOCK_WAIT");
    ctx->waitTimeoutMs = GetEnvIntClamped("KANGAROO_METAL_WAIT_TIMEOUT_MS", 3000, 100, 60000);
    ctx->walkersPerLaunch =
        (double)nbThreadGroup * (double)nbThreadPerGroup * (double)groupSize * (double)runCount;

    if(ctx->profileEnabled || ctx->invProfileEnabled) {
      printf("GPUEngine(Metal): profile on (threadExecutionWidth=%lu maxThreads/group=%lu nbRun=%d grp=%d stateCache=%s waitTimeoutMs=%d blockWait=%s invProfile=%s)\n",
             (unsigned long)[ctx->pipeline threadExecutionWidth],
             (unsigned long)[ctx->pipeline maxTotalThreadsPerThreadgroup],
             runCount,
             groupSize,
             GetStateCacheModeName(ctx->activeStateCacheMode),
             ctx->waitTimeoutMs,
             ctx->blockWaitEnabled ? "on" : "off",
             ctx->invProfileEnabled ? "on" : "off");
    }
    if(ctx->autoMode14Enabled) {
      printf("GPUEngine(Metal): auto stateCache(1/4) enabled (initial=none, benchmark after kangaroo upload)\n");
    }

    char tmp[512];
    snprintf(tmp,
             sizeof(tmp),
             "GPU #%d %s (Metal, experimental) Grid(%dx%d)",
             gpuId,
             [[ctx->device name] UTF8String],
             nbThreadGroup,
             nbThreadPerGroup);
    deviceName = string(tmp);
  }

  wildOffset.SetInt32(0);
  initialised = true;
}

GPUEngine::~GPUEngine() {
  if(inputKangarooPinned != nullptr) {
    ::free(inputKangarooPinned);
    inputKangarooPinned = nullptr;
  }
  if(outputItemPinned != nullptr) {
    ::free(outputItemPinned);
    outputItemPinned = nullptr;
  }
  if(jumpPinned != nullptr) {
    ::free(jumpPinned);
    jumpPinned = nullptr;
  }

  MetalContext *ctx = reinterpret_cast<MetalContext *>(backendContext);
  if(ctx != nullptr) {
    WaitForInflight(ctx, true);
    delete ctx;
  }
  backendContext = nullptr;
}

int GPUEngine::GetMemory() {
  uint32_t jumpMem = jumpSize / 2 + jumpSize + jumpSize;
  return kangarooSize + 2 * outputSize + jumpMem;
}

int GPUEngine::GetGroupSize() { return groupSize; }

bool GPUEngine::GetGridSize(int gpuId, int *x, int *y) {

  if(*x > 0 && *y > 0) {
    return true;
  }

  @autoreleasepool {
    NSArray<id<MTLDevice>> *devices = MTLCopyAllDevices();
    if(devices == nil || [devices count] == 0) {
      printf("GPUEngine(Metal): no Metal device available\n");
      return false;
    }

    if(gpuId < 0 || (NSUInteger)gpuId >= [devices count]) {
      printf("GPUEngine(Metal): invalid gpuId\n");
      return false;
    }

    id<MTLDevice> device = [devices objectAtIndex:(NSUInteger)gpuId];
    NSUInteger maxTg = [device maxThreadsPerThreadgroup].width;
    if(maxTg == 0) {
      maxTg = 256;
    }

    if(*y <= 0) {
      NSUInteger preferred = 256;
      if(preferred > maxTg) {
        preferred = maxTg;
      }
      if(preferred == 0) {
        preferred = 1;
      }
      *y = (int)preferred;
    }

    if(*x <= 0) {
      *x = 64;
    }
  }

  return true;
}

void *GPUEngine::AllocatePinnedMemory(size_t size) { return ::malloc(size); }

void GPUEngine::FreePinnedMemory(void *buff) {
  if(buff != nullptr) {
    ::free(buff);
  }
}

void GPUEngine::PrintCudaInfo() {
  @autoreleasepool {
    NSArray<id<MTLDevice>> *devices = MTLCopyAllDevices();
    if(devices == nil || [devices count] == 0) {
      printf("GPUEngine(Metal): no Metal device available\n");
      return;
    }

    for(NSUInteger i = 0; i < [devices count]; i++) {
      id<MTLDevice> d = [devices objectAtIndex:i];
      printf("GPU #%lu %s (Metal) (max threads/group: %lu)\n",
             (unsigned long)i,
             [[d name] UTF8String],
             (unsigned long)[d maxThreadsPerThreadgroup].width);
    }
  }
}

bool GPUEngine::RunUnitTests(int gpuId, int testCount) {

  if(testCount <= 0) {
    return true;
  }

  @autoreleasepool {
    NSArray<id<MTLDevice>> *devices = MTLCopyAllDevices();
    if(devices == nil || [devices count] == 0) {
      printf("GPUEngine(Metal): no Metal device available for unit tests\n");
      return false;
    }

    if(gpuId < 0 || (NSUInteger)gpuId >= [devices count]) {
      printf("GPUEngine(Metal): invalid gpuId for unit tests\n");
      return false;
    }

    id<MTLDevice> device = [devices objectAtIndex:(NSUInteger)gpuId];
    id<MTLCommandQueue> queue = [device newCommandQueue];
    if(queue == nil) {
      printf("GPUEngine(Metal): cannot create command queue for unit tests\n");
      return false;
    }

    string pipelineErr;
    const int grpSize =
        GetEnvIntClamped("KANGAROO_METAL_GRP_SIZE",
                         16,
                         1,
                         std::min<int>(GPU_GRP_SIZE, kMetalMaxGroupSize));
    const int nbRun =
        GetEnvIntClamped("KANGAROO_METAL_NB_RUN", 4, 1, NB_RUN);
    id<MTLComputePipelineState> pipeline =
        BuildPipeline(device, "metal_unit_test", pipelineErr, grpSize, nbRun);
    if(pipeline == nil) {
      printf("GPUEngine(Metal): %s\n", pipelineErr.c_str());
      return false;
    }

    Secp256K1 secp;
    secp.Init();

    vector<MathTestInput> inputs((size_t)testCount);
    vector<MathTestOutput> expected((size_t)testCount);
    Int fieldP(Int::GetFieldCharacteristic());
    Int fieldPMinus1(&fieldP);
    fieldPMinus1.SubOne();

    for(int i = 0; i < testCount; i++) {
      Int a;
      Int b;

      if(i == 0) {
        a.SetInt32(0);
        b.SetInt32(0);
      } else if(i == 1) {
        a.SetInt32(1);
        b.SetInt32(1);
      } else if(i == 2) {
        a.Set(&fieldPMinus1);
        b.Set(&fieldPMinus1);
      } else {
        do {
          a.Rand(256);
          a.Mod(Int::GetFieldCharacteristic());
        } while(a.IsZero());

        b.Rand(256);
        b.Mod(Int::GetFieldCharacteristic());
      }

      CopyIntTo4(a, inputs[(size_t)i].a);
      CopyIntTo4(b, inputs[(size_t)i].b);

      Int mul;
      mul.ModMulK1(&a, &b);
      CopyIntTo4(mul, expected[(size_t)i].mul);

      Int sqr;
      sqr.ModSquareK1(&a);
      CopyIntTo4(sqr, expected[(size_t)i].sqr);

      Int inv(&a);
      inv.ModInv();
      CopyIntTo4(inv, expected[(size_t)i].inv);

      bool pointReady = false;
      Point P;
      Point J;
      Point R;
      for(int retry = 0; retry < 64 && !pointReady; retry++) {
        Int kp;
        Int kj;

        do {
          kp.Rand(256);
          kp.Mod(&secp.order);
        } while(kp.IsZero());

        do {
          kj.Rand(256);
          kj.Mod(&secp.order);
        } while(kj.IsZero());

        P = secp.ComputePublicKey(&kp);
        J = secp.ComputePublicKey(&kj);

        if(!P.x.IsEqual(&J.x)) {
          R = secp.AddDirect(J, P);
          pointReady = true;
        }
      }

      if(!pointReady) {
        printf("GPUEngine(Metal): failed to generate non-singular point pair for unit test\n");
        return false;
      }

      CopyIntTo4(P.x, inputs[(size_t)i].px);
      CopyIntTo4(P.y, inputs[(size_t)i].py);
      CopyIntTo4(J.x, inputs[(size_t)i].jx);
      CopyIntTo4(J.y, inputs[(size_t)i].jy);

      CopyIntTo4(R.x, expected[(size_t)i].rx);
      CopyIntTo4(R.y, expected[(size_t)i].ry);
      expected[(size_t)i].flags = 0;
      expected[(size_t)i].pad = 0;
    }

    id<MTLBuffer> inBuf = [device newBufferWithLength:(inputs.size() * sizeof(MathTestInput))
                                               options:MTLResourceStorageModeShared];
    id<MTLBuffer> outBuf = [device newBufferWithLength:(expected.size() * sizeof(MathTestOutput))
                                                options:MTLResourceStorageModeShared];
    id<MTLBuffer> countBuf = [device newBufferWithLength:sizeof(uint32_t)
                                                 options:MTLResourceStorageModeShared];

    if(inBuf == nil || outBuf == nil || countBuf == nil) {
      printf("GPUEngine(Metal): failed to allocate unit test buffers\n");
      return false;
    }

    memcpy([inBuf contents], inputs.data(), inputs.size() * sizeof(MathTestInput));
    memset([outBuf contents], 0, expected.size() * sizeof(MathTestOutput));
    uint32_t count = (uint32_t)testCount;
    memcpy([countBuf contents], &count, sizeof(uint32_t));

    id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
    if(commandBuffer == nil) {
      printf("GPUEngine(Metal): failed to create unit test command buffer\n");
      return false;
    }

    id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
    if(encoder == nil) {
      printf("GPUEngine(Metal): failed to create unit test encoder\n");
      return false;
    }

    [encoder setComputePipelineState:pipeline];
    [encoder setBuffer:inBuf offset:0 atIndex:0];
    [encoder setBuffer:outBuf offset:0 atIndex:1];
    [encoder setBuffer:countBuf offset:0 atIndex:2];

    NSUInteger threads = [pipeline maxTotalThreadsPerThreadgroup];
    if(threads == 0) {
      threads = 64;
    }
    threads = std::min<NSUInteger>(threads, 256);

    MTLSize tg = MTLSizeMake(threads, 1, 1);
    MTLSize grid = MTLSizeMake((NSUInteger)(((uint32_t)testCount + (uint32_t)threads - 1U) /
                                           (uint32_t)threads),
                               1,
                               1);

    [encoder dispatchThreadgroups:grid threadsPerThreadgroup:tg];
    [encoder endEncoding];

    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];

    if([commandBuffer status] != MTLCommandBufferStatusCompleted) {
      NSError *error = [commandBuffer error];
      if(error != nil) {
        printf("GPUEngine(Metal): unit test kernel failed: %s\n",
               [[error localizedDescription] UTF8String]);
      } else {
        printf("GPUEngine(Metal): unit test kernel failed\n");
      }
      return false;
    }

    MathTestOutput *got = reinterpret_cast<MathTestOutput *>([outBuf contents]);

    for(int i = 0; i < testCount; i++) {
      const MathTestOutput &exp = expected[(size_t)i];
      const MathTestOutput &act = got[(size_t)i];

      if(act.flags != exp.flags || !Eq4(act.mul, exp.mul) || !Eq4(act.sqr, exp.sqr) ||
         !Eq4(act.inv, exp.inv) || !Eq4(act.rx, exp.rx) || !Eq4(act.ry, exp.ry)) {
        printf("GPUEngine(Metal): unit test mismatch at #%d\n", i);
        printf(" flags exp=%u act=%u\n", exp.flags, act.flags);
        Print4(" mul.exp", exp.mul);
        Print4(" mul.act", act.mul);
        Print4(" sqr.exp", exp.sqr);
        Print4(" sqr.act", act.sqr);
        Print4(" inv.exp", exp.inv);
        Print4(" inv.act", act.inv);
        Print4(" addx.exp", exp.rx);
        Print4(" addx.act", act.rx);
        Print4(" addy.exp", exp.ry);
        Print4(" addy.act", act.ry);
        return false;
      }
    }
  }

  return true;
}

int GPUEngine::GetDefaultGroupSize() {
  return GetEnvIntClamped(
      "KANGAROO_METAL_GRP_SIZE", 16, 1, std::min<int>(GPU_GRP_SIZE, kMetalMaxGroupSize));
}

int GPUEngine::GetNbThread() { return nbThread; }

int GPUEngine::GetRunCount() const { return runCount; }

int GPUEngine::GetStateCacheMode() const {
  MetalContext *ctx = reinterpret_cast<MetalContext *>(backendContext);
  if(ctx == nullptr) {
    return -1;
  }
  return ctx->activeStateCacheMode;
}

bool GPUEngine::GetKangarooSymClass(uint64_t kIdx,uint64_t *symClass) {
#ifdef USE_SYMMETRY
  if(symClass == nullptr || !initialised) {
    return false;
  }

  MetalContext *ctx = reinterpret_cast<MetalContext *>(backendContext);
  if(ctx == nullptr) {
    return false;
  }

  if(!WaitForInflight(ctx, true)) {
    return false;
  }

  uint64_t walkersPerBlock = (uint64_t)nbThreadPerGroup * (uint64_t)groupSize;
  if(walkersPerBlock == 0) {
    return false;
  }
  uint64_t b = kIdx / walkersPerBlock;
  uint64_t rem = kIdx % walkersPerBlock;
  uint64_t g = rem / (uint64_t)nbThreadPerGroup;
  uint64_t t = rem % (uint64_t)nbThreadPerGroup;
  uint64_t nbBlock = (uint64_t)nbThread / (uint64_t)nbThreadPerGroup;
  if(b >= nbBlock) {
    return false;
  }

  uint64_t gSize = (uint64_t)KSIZE * (uint64_t)groupSize;
  uint64_t strideSize = (uint64_t)nbThreadPerGroup * (uint64_t)KSIZE;
  uint64_t blockSize = (uint64_t)nbThreadPerGroup * gSize;
  uint64_t idx = b * blockSize + g * strideSize + t + 10ull * (uint64_t)nbThreadPerGroup;
  *symClass = inputKangaroo[idx] & 1ULL;
  return true;
#else
  (void)kIdx;
  (void)symClass;
  return false;
#endif
}

void GPUEngine::SetKangaroos(Int *px, Int *py, Int *d) {
  SetKangaroos(px, py, d, nullptr);
}

void GPUEngine::SetKangaroos(Int *px, Int *py, Int *d, uint64_t *symClass) {

  if(!initialised) {
    return;
  }

  int gSize = KSIZE * groupSize;
  int strideSize = nbThreadPerGroup * KSIZE;
  int nbBlock = nbThread / nbThreadPerGroup;
  int blockSize = nbThreadPerGroup * gSize;
  int idx = 0;

  for(int b = 0; b < nbBlock; b++) {
    for(int g = 0; g < groupSize; g++) {
      for(int t = 0; t < nbThreadPerGroup; t++) {

        inputKangarooPinned[g * strideSize + t + 0 * nbThreadPerGroup] = px[idx].bits64[0];
        inputKangarooPinned[g * strideSize + t + 1 * nbThreadPerGroup] = px[idx].bits64[1];
        inputKangarooPinned[g * strideSize + t + 2 * nbThreadPerGroup] = px[idx].bits64[2];
        inputKangarooPinned[g * strideSize + t + 3 * nbThreadPerGroup] = px[idx].bits64[3];

        inputKangarooPinned[g * strideSize + t + 4 * nbThreadPerGroup] = py[idx].bits64[0];
        inputKangarooPinned[g * strideSize + t + 5 * nbThreadPerGroup] = py[idx].bits64[1];
        inputKangarooPinned[g * strideSize + t + 6 * nbThreadPerGroup] = py[idx].bits64[2];
        inputKangarooPinned[g * strideSize + t + 7 * nbThreadPerGroup] = py[idx].bits64[3];

        Int dOff;
        dOff.Set(&d[idx]);
#ifndef USE_SYMMETRY
        // Non-symmetry kernels keep wild walks in offset form on device.
        if(idx % 2 == WILD) {
          dOff.ModAddK1order(&wildOffset);
        }
#endif
#ifdef USE_SYMMETRY
        uint64_t gpuD0;
        uint64_t gpuD1;
        EncodeGpuDistanceSym(&dOff,&gpuD0,&gpuD1);
        inputKangarooPinned[g * strideSize + t + 8 * nbThreadPerGroup] = gpuD0;
        inputKangarooPinned[g * strideSize + t + 9 * nbThreadPerGroup] = gpuD1;
#else
        inputKangarooPinned[g * strideSize + t + 8 * nbThreadPerGroup] = dOff.bits64[0];
        inputKangarooPinned[g * strideSize + t + 9 * nbThreadPerGroup] = dOff.bits64[1];
#endif

#ifdef USE_SYMMETRY
        uint64_t sc = 0ULL;
        if(symClass != nullptr) {
          sc = symClass[idx] & 1ULL;
        }
        // Metal symmetry kernels persist per-walker symmetry class (0/1).
        inputKangarooPinned[g * strideSize + t + 10 * nbThreadPerGroup] = sc;
#endif

        idx++;
      }
    }

    uint32_t offset = b * blockSize;
    memcpy(inputKangaroo + offset, inputKangarooPinned, kangarooSizePinned);
  }

  MetalContext *ctx = reinterpret_cast<MetalContext *>(backendContext);
  if(ctx == nullptr || !ctx->autoMode14Enabled || ctx->autoMode14Evaluated) {
    return;
  }

  if(ctx->pipelineMode1 == nil || ctx->pipelineMode4 == nil) {
    ctx->pipeline = (ctx->pipelineMode1 != nil) ? ctx->pipelineMode1 : ctx->pipeline;
    ctx->activeStateCacheMode = 1;
    ctx->autoMode14Enabled = false;
    ctx->autoMode14Evaluated = true;
    return;
  }

  if(!WaitForInflight(ctx, true)) {
    printf("GPUEngine(Metal): auto stateCache benchmark skipped (inflight command failed), fallback to stateCache=none\n");
    ctx->pipeline = ctx->pipelineMode1;
    ctx->activeStateCacheMode = 1;
    ctx->autoMode14Enabled = false;
    ctx->autoMode14Evaluated = true;
    return;
  }

  vector<uint64_t> kangarooSnapshot((size_t)kangarooSize / sizeof(uint64_t));
  memcpy(kangarooSnapshot.data(), inputKangaroo, kangarooSize);

  // 🟢 优化：改进 Auto Mode 采样质量
  // - warmup: 1→3 次（更充分预热 L2 cache）
  // - benchmark: 2→5 次（更准确的性能测量）
  // - minGain: 0→2% （避免因噪声切换到非最优模式）
  const int warmupIters = GetEnvIntClamped("KANGAROO_METAL_AUTO_MODE14_WARMUP", 3, 0, 8);
  const int benchIters = GetEnvIntClamped("KANGAROO_METAL_AUTO_MODE14_ITERS", 5, 1, 16);
  const int minGainPct = GetEnvIntClamped("KANGAROO_METAL_AUTO_MODE14_MIN_GAIN_PCT", 2, 0, 50);

  const bool savedProfileEnabled = ctx->profileEnabled;
  const bool savedInvProfileEnabled = ctx->invProfileEnabled;
  const uint64_t savedCompletedLaunches = ctx->completedLaunches;
  const double savedAccumulatedGpuMs = ctx->accumulatedGpuMs;
  const uint64_t savedInvCallsAccum = ctx->invCallsAccum;
  const uint64_t savedInvFallbackAccum = ctx->invFallbackAccum;
  const uint64_t savedInvIterAccum = ctx->invIterAccum;
  const uint32_t savedInvIterMax = ctx->invIterMax;
  const uint64_t savedInvFallbackIterLimitAccum = ctx->invFallbackIterLimitAccum;
  const uint64_t savedInvFallbackGcdAccum = ctx->invFallbackGcdAccum;
  const uint64_t savedInvFallbackNormNegAccum = ctx->invFallbackNormNegAccum;
  const uint64_t savedInvFallbackNormPosAccum = ctx->invFallbackNormPosAccum;

  auto resetTransientState = [&]() {
    ctx->inflight = nil;
    ctx->inflightBufferIdx = -1;
    ctx->writeBufferIdx = 0;
    memset(ctx->outputWords[0], 0, outputSize);
    memset(ctx->outputWords[1], 0, outputSize);
    memset(ctx->invProfileWords, 0, 8 * sizeof(uint32_t));
  };

  auto benchMode = [&](id<MTLComputePipelineState> pipeline, int mode, double &avgMs) -> bool {
    memcpy(inputKangaroo, kangarooSnapshot.data(), kangarooSize);
    resetTransientState();
    ctx->pipeline = pipeline;
    ctx->activeStateCacheMode = mode;

    for(int i = 0; i < warmupIters; i++) {
      if(!callKernelAndWait()) {
        return false;
      }
    }

    double t0 = Timer::get_tick();
    for(int i = 0; i < benchIters; i++) {
      if(!callKernelAndWait()) {
        return false;
      }
    }
    avgMs = ((Timer::get_tick() - t0) * 1000.0) / (double)benchIters;
    return true;
  };

  ctx->profileEnabled = false;
  ctx->invProfileEnabled = false;

  double mode1Ms = 0.0;
  double mode4Ms = 0.0;
  bool mode1Ok = benchMode(ctx->pipelineMode1, 1, mode1Ms);
  bool mode4Ok = mode1Ok && benchMode(ctx->pipelineMode4, 4, mode4Ms);

  ctx->profileEnabled = savedProfileEnabled;
  ctx->invProfileEnabled = savedInvProfileEnabled;
  ctx->completedLaunches = savedCompletedLaunches;
  ctx->accumulatedGpuMs = savedAccumulatedGpuMs;
  ctx->invCallsAccum = savedInvCallsAccum;
  ctx->invFallbackAccum = savedInvFallbackAccum;
  ctx->invIterAccum = savedInvIterAccum;
  ctx->invIterMax = savedInvIterMax;
  ctx->invFallbackIterLimitAccum = savedInvFallbackIterLimitAccum;
  ctx->invFallbackGcdAccum = savedInvFallbackGcdAccum;
  ctx->invFallbackNormNegAccum = savedInvFallbackNormNegAccum;
  ctx->invFallbackNormPosAccum = savedInvFallbackNormPosAccum;

  memcpy(inputKangaroo, kangarooSnapshot.data(), kangarooSize);
  resetTransientState();

  if(!mode1Ok || !mode4Ok) {
    printf("GPUEngine(Metal): auto stateCache benchmark failed, fallback to stateCache=none\n");
    ctx->pipeline = ctx->pipelineMode1;
    ctx->activeStateCacheMode = 1;
    ctx->autoMode14Enabled = false;
    ctx->autoMode14Evaluated = true;
    return;
  }

  const double minGain = 1.0 - ((double)minGainPct / 100.0);
  const bool pickMode4 = mode4Ms < (mode1Ms * minGain);
  ctx->pipeline = pickMode4 ? ctx->pipelineMode4 : ctx->pipelineMode1;
  ctx->activeStateCacheMode = pickMode4 ? 4 : 1;
  ctx->autoMode14Enabled = false;
  ctx->autoMode14Evaluated = true;

  double mode1Mkps = 0.0;
  double mode4Mkps = 0.0;
  if(mode1Ms > 0.0) {
    mode1Mkps = (ctx->walkersPerLaunch / (mode1Ms / 1000.0)) / 1000000.0;
  }
  if(mode4Ms > 0.0) {
    mode4Mkps = (ctx->walkersPerLaunch / (mode4Ms / 1000.0)) / 1000000.0;
  }

  printf("GPUEngine(Metal): auto stateCache selected %s (none=%.3f ms %.2f MK/s, simd=%.3f ms %.2f MK/s, minGain=%d%%)\n",
         GetStateCacheModeName(ctx->activeStateCacheMode),
         mode1Ms,
         mode1Mkps,
         mode4Ms,
         mode4Mkps,
         minGainPct);
}

void GPUEngine::GetKangaroos(Int *px, Int *py, Int *d) {
  GetKangaroos(px, py, d, nullptr);
}

void GPUEngine::GetKangaroos(Int *px, Int *py, Int *d, uint64_t *symClass) {

  if(!initialised || inputKangarooPinned == nullptr) {
    printf("GPUEngine(Metal): GetKangaroos: cannot retrieve kangaroos\n");
    return;
  }

  // Match CUDA behavior: host read must observe completed kernel state.
  MetalContext *ctx = reinterpret_cast<MetalContext *>(backendContext);
  if(!WaitForInflight(ctx, true)) {
    printf("GPUEngine(Metal): GetKangaroos: inflight command failed\n");
    return;
  }

  int gSize = KSIZE * groupSize;
  int strideSize = nbThreadPerGroup * KSIZE;
  int nbBlock = nbThread / nbThreadPerGroup;
  int blockSize = nbThreadPerGroup * gSize;
  int idx = 0;

  for(int b = 0; b < nbBlock; b++) {
    uint32_t offset = b * blockSize;
    memcpy(inputKangarooPinned, inputKangaroo + offset, kangarooSizePinned);

    for(int g = 0; g < groupSize; g++) {
      for(int t = 0; t < nbThreadPerGroup; t++) {

        px[idx].bits64[0] = inputKangarooPinned[g * strideSize + t + 0 * nbThreadPerGroup];
        px[idx].bits64[1] = inputKangarooPinned[g * strideSize + t + 1 * nbThreadPerGroup];
        px[idx].bits64[2] = inputKangarooPinned[g * strideSize + t + 2 * nbThreadPerGroup];
        px[idx].bits64[3] = inputKangarooPinned[g * strideSize + t + 3 * nbThreadPerGroup];
        px[idx].bits64[4] = 0;

        py[idx].bits64[0] = inputKangarooPinned[g * strideSize + t + 4 * nbThreadPerGroup];
        py[idx].bits64[1] = inputKangarooPinned[g * strideSize + t + 5 * nbThreadPerGroup];
        py[idx].bits64[2] = inputKangarooPinned[g * strideSize + t + 6 * nbThreadPerGroup];
        py[idx].bits64[3] = inputKangarooPinned[g * strideSize + t + 7 * nbThreadPerGroup];
        py[idx].bits64[4] = 0;

        Int dOff;
        dOff.SetInt32(0);
#ifdef USE_SYMMETRY
        DecodeGpuDistanceSym(inputKangarooPinned[g * strideSize + t + 8 * nbThreadPerGroup],
                             inputKangarooPinned[g * strideSize + t + 9 * nbThreadPerGroup],&dOff);
#else
        dOff.bits64[0] = inputKangarooPinned[g * strideSize + t + 8 * nbThreadPerGroup];
        dOff.bits64[1] = inputKangarooPinned[g * strideSize + t + 9 * nbThreadPerGroup];
#endif
#ifndef USE_SYMMETRY
        if(idx % 2 == WILD) {
          dOff.ModSubK1order(&wildOffset);
        }
#endif
        d[idx].Set(&dOff);

#ifdef USE_SYMMETRY
        if(symClass != nullptr) {
          symClass[idx] =
              inputKangarooPinned[g * strideSize + t + 10 * nbThreadPerGroup] & 1ULL;
        }
#endif

        idx++;
      }
    }
  }
}

void GPUEngine::SetKangaroo(uint64_t kIdx, Int *px, Int *py, Int *d) {
  SetKangaroo(kIdx, px, py, d, 0ULL);
}

void GPUEngine::SetKangaroo(uint64_t kIdx, Int *px, Int *py, Int *d, uint64_t symClass) {

  if(!initialised) {
    return;
  }

  // Keep host write serialized with GPU execution on shared storage.
  MetalContext *ctx = reinterpret_cast<MetalContext *>(backendContext);
  if(!WaitForInflight(ctx, true)) {
    printf("GPUEngine(Metal): SetKangaroo: inflight command failed\n");
    return;
  }

  int gSize = KSIZE * groupSize;
  int strideSize = nbThreadPerGroup * KSIZE;
  int blockSize = nbThreadPerGroup * gSize;

  uint64_t t = kIdx % nbThreadPerGroup;
  uint64_t g = (kIdx / nbThreadPerGroup) % (uint64_t)groupSize;
  uint64_t b = kIdx / (nbThreadPerGroup * (uint64_t)groupSize);

  inputKangaroo[b * blockSize + g * strideSize + t + 0 * nbThreadPerGroup] = px->bits64[0];
  inputKangaroo[b * blockSize + g * strideSize + t + 1 * nbThreadPerGroup] = px->bits64[1];
  inputKangaroo[b * blockSize + g * strideSize + t + 2 * nbThreadPerGroup] = px->bits64[2];
  inputKangaroo[b * blockSize + g * strideSize + t + 3 * nbThreadPerGroup] = px->bits64[3];

  inputKangaroo[b * blockSize + g * strideSize + t + 4 * nbThreadPerGroup] = py->bits64[0];
  inputKangaroo[b * blockSize + g * strideSize + t + 5 * nbThreadPerGroup] = py->bits64[1];
  inputKangaroo[b * blockSize + g * strideSize + t + 6 * nbThreadPerGroup] = py->bits64[2];
  inputKangaroo[b * blockSize + g * strideSize + t + 7 * nbThreadPerGroup] = py->bits64[3];

  Int dOff;
  dOff.Set(d);
#ifndef USE_SYMMETRY
  if(kIdx % 2 == WILD) {
    dOff.ModAddK1order(&wildOffset);
  }
#endif

#ifdef USE_SYMMETRY
  uint64_t gpuD0;
  uint64_t gpuD1;
  EncodeGpuDistanceSym(&dOff,&gpuD0,&gpuD1);
  inputKangaroo[b * blockSize + g * strideSize + t + 8 * nbThreadPerGroup] = gpuD0;
  inputKangaroo[b * blockSize + g * strideSize + t + 9 * nbThreadPerGroup] = gpuD1;
#else
  inputKangaroo[b * blockSize + g * strideSize + t + 8 * nbThreadPerGroup] = dOff.bits64[0];
  inputKangaroo[b * blockSize + g * strideSize + t + 9 * nbThreadPerGroup] = dOff.bits64[1];
#endif

#ifdef USE_SYMMETRY
  inputKangaroo[b * blockSize + g * strideSize + t + 10 * nbThreadPerGroup] = symClass & 1ULL;
#endif
}

bool GPUEngine::callKernel() {

  if(!initialised) {
    return false;
  }

  MetalContext *ctx = reinterpret_cast<MetalContext *>(backendContext);
  if(ctx == nullptr || ctx->pipeline == nil || ctx->queue == nil) {
    return false;
  }

  // 🟢 优化：移除此处的 WaitForInflight，让 Launch() 集中管理等待时机
  // 原因：在 Launch() 中已经等待，这里再等待会破坏 GPU-CPU 并行
  // if(!WaitForInflight(ctx, false)) {
  //   return false;
  // }

  int writeIdx = ctx->writeBufferIdx;
  ctx->outputWords[writeIdx][0] = 0;
  if(ctx->invProfileEnabled && ctx->invProfileWords != nullptr) {
    for(int i = 0; i < 8; i++) {
      ctx->invProfileWords[i] = 0;
    }
  }

  // @autoreleasepool 确保每次 kernel dispatch 产生的 ObjC 临时对象
  // (MTLCommandBuffer, MTLComputeCommandEncoder 等) 在本次调用结束后立即释放，
  // 避免在 C++ 线程的长期循环中累积导致虚拟内存耗尽。
  @autoreleasepool {

  id<MTLCommandBuffer> commandBuffer = [ctx->queue commandBuffer];
  if(commandBuffer == nil) {
    printf("GPUEngine(Metal): failed to create command buffer\n");
    return false;
  }
  commandBuffer.label = @"kangaroo_step";

  id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
  if(encoder == nil) {
    printf("GPUEngine(Metal): failed to create compute encoder\n");
    return false;
  }
  encoder.label = @"kangaroo_step";

  KernelParams params;
  params.maxFound = maxFound;
  params.nbThreadPerGroup = nbThreadPerGroup;
  params.nbThreadGroup = nbThread / nbThreadPerGroup;
  params.nbRun = (uint32_t)runCount;
  params.kSize = KSIZE;
  params.gpuGroupSize = (uint32_t)groupSize;
  params.profileMode = ctx->invProfileEnabled ? 1u : 0u;
  params.paramPad = 0;  // 显式清零 padding 字段
  params.dpMask = dpMask;

  [encoder setComputePipelineState:ctx->pipeline];
  [encoder setBuffer:ctx->kangarooBuffer offset:0 atIndex:0];
  [encoder setBuffer:ctx->outputBuffers[writeIdx] offset:0 atIndex:1];
  [encoder setBuffer:ctx->jumpDistBuffer offset:0 atIndex:2];
  [encoder setBuffer:ctx->jumpXBuffer offset:0 atIndex:3];
  [encoder setBuffer:ctx->jumpYBuffer offset:0 atIndex:4];
  [encoder setBytes:&params length:sizeof(params) atIndex:5];
  [encoder setBuffer:ctx->invProfileBuffer offset:0 atIndex:6];

  MTLSize threadsPerThreadgroup = MTLSizeMake(nbThreadPerGroup, 1, 1);
  MTLSize threadgroupsPerGrid = MTLSizeMake(params.nbThreadGroup, 1, 1);

  [encoder dispatchThreadgroups:threadgroupsPerGrid threadsPerThreadgroup:threadsPerThreadgroup];
  [encoder endEncoding];

  [commandBuffer commit];

  ctx->inflight = commandBuffer;
  ctx->inflightBufferIdx = writeIdx;
  ctx->writeBufferIdx = (writeIdx == 0) ? 1 : 0;

  } // @autoreleasepool

  return true;
}

void GPUEngine::SetParams(uint64_t dpMask, Int *distance, Int *px, Int *py) {

  if(!initialised) {
    return;
  }

  MetalContext *ctx = reinterpret_cast<MetalContext *>(backendContext);
  if(ctx == nullptr) {
    return;
  }

  this->dpMask = dpMask;

  uint64_t *jumpDistOut = reinterpret_cast<uint64_t *>([ctx->jumpDistBuffer contents]);
  uint64_t *jumpXOut = reinterpret_cast<uint64_t *>([ctx->jumpXBuffer contents]);
  uint64_t *jumpYOut = reinterpret_cast<uint64_t *>([ctx->jumpYBuffer contents]);

  for(int i = 0; i < NB_JUMP; i++) {
    memcpy(jumpPinned + 2 * i, distance[i].bits64, 16);
  }
  memcpy(jumpDistOut, jumpPinned, NB_JUMP * 2 * sizeof(uint64_t));

  for(int i = 0; i < NB_JUMP; i++) {
    memcpy(jumpPinned + 4 * i, px[i].bits64, 32);
  }
  memcpy(jumpXOut, jumpPinned, NB_JUMP * 4 * sizeof(uint64_t));

  for(int i = 0; i < NB_JUMP; i++) {
    memcpy(jumpPinned + 4 * i, py[i].bits64, 32);
  }
  memcpy(jumpYOut, jumpPinned, NB_JUMP * 4 * sizeof(uint64_t));
}

bool GPUEngine::callKernelAndWait() {

  if(!callKernel()) {
    return false;
  }

  MetalContext *ctx = reinterpret_cast<MetalContext *>(backendContext);
  if(!WaitForInflight(ctx, true)) {
    return false;
  }

  if(ctx->inflightBufferIdx < 0) {
    return false;
  }

  memcpy(outputItemPinned, ctx->outputWords[ctx->inflightBufferIdx], outputSize);
  return true;
}

bool GPUEngine::Launch(std::vector<ITEM> &hashFound, bool spinWait) {

  hashFound.clear();

  if(!initialised) {
    return false;
  }

  MetalContext *ctx = reinterpret_cast<MetalContext *>(backendContext);

  // 🟢 优化：先提交下一个kernel，再等待上一个kernel完成，实现真正的并行
  int doneIdx = ctx->inflightBufferIdx;
  if(doneIdx < 0) {
    // 首次调用：直接提交kernel，无需等待
    return callKernel();
  }

  // 后续调用：
  // 1. 保存上一个kernel的引用（因为callKernel会更新ctx->inflight）
  id<MTLCommandBuffer> previousKernel = ctx->inflight;

  // 2. 提交下一个kernel（不阻塞）
  bool launchOk = callKernel();

  // 3. 等待上一个kernel完成（使用保存的引用）
  if(previousKernel != nil) {
    if(spinWait || ctx->blockWaitEnabled) {
      [previousKernel waitUntilCompleted];
    } else {
      double t0 = Timer::get_tick();
      while(true) {
        MTLCommandBufferStatus status = [previousKernel status];
        if(status == MTLCommandBufferStatusCompleted || status == MTLCommandBufferStatusError) {
          break;
        }
        if(ctx->waitTimeoutMs > 0) {
          double elapsedMs = (Timer::get_tick() - t0) * 1000.0;
          if(elapsedMs >= (double)ctx->waitTimeoutMs) {
            printf("GPUEngine(Metal): command buffer timeout after %.0f ms\n", elapsedMs);
            return false;
          }
        }
        Timer::SleepMillis(1);
      }
    }

    if([previousKernel status] != MTLCommandBufferStatusCompleted) {
      NSError *error = [previousKernel error];
      if(error != nil) {
        printf("GPUEngine(Metal): command buffer failed: %s\n",
               [[error localizedDescription] UTF8String]);
      } else {
        printf("GPUEngine(Metal): command buffer failed\n");
      }
      return false;
    }
  }

  uint32_t *doneOutput = ctx->outputWords[doneIdx];

  uint32_t nbFound = doneOutput[0];
  if(nbFound > maxFound) {
    if(!lostWarning) {
      printf("\nWarning, %d items lost\nHint: Search with less threads (-g) or increse dp (-d)\n",
             (nbFound - maxFound));
      lostWarning = true;
    }
    nbFound = maxFound;
  }

  for(uint32_t i = 0; i < nbFound; i++) {
    uint32_t *itemPtr = doneOutput + (i * ITEM_SIZE32 + 1);
    ITEM it;

    it.kIdx = *((uint64_t *)(itemPtr + 12));

    uint64_t *x = (uint64_t *)itemPtr;
    it.x.bits64[0] = x[0];
    it.x.bits64[1] = x[1];
    it.x.bits64[2] = x[2];
    it.x.bits64[3] = x[3];
    it.x.bits64[4] = 0;

    uint64_t *d = (uint64_t *)(itemPtr + 8);
#ifdef USE_SYMMETRY
    DecodeGpuDistanceSym(d[0],d[1],&it.d);
#else
    it.d.bits64[0] = d[0];
    it.d.bits64[1] = d[1];
    it.d.bits64[2] = 0;
    it.d.bits64[3] = 0;
    it.d.bits64[4] = 0;
#endif
#ifndef USE_SYMMETRY
    if(it.kIdx % 2 == WILD) {
      it.d.ModSubK1order(&wildOffset);
    }
#endif

    hashFound.push_back(it);
  }

  return launchOk;
}
