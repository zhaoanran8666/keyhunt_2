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

#ifndef GPUENGINEH
#define GPUENGINEH

#include <vector>
#include "../Constants.h"
#include "../SECPK1/SECP256k1.h"

#ifdef USE_SYMMETRY
#define KSIZE 12
#else
#define KSIZE 11
#endif

#define ITEM_SIZE   64
#define ITEM_SIZE32 (ITEM_SIZE/4)

typedef struct {
  Int x;
  Int d;
  uint64_t kIdx;
} ITEM;

#ifdef USE_SYMMETRY
static inline constexpr uint64_t kGpuDistSignBit = 1ULL << 63;

// GPU symmetry path stores 192-bit signed-magnitude distance:
// d2 bit 63 = sign, d2 bit 62 = kType, remaining bits are |d| (190-bit magnitude).
// CPU keeps distance as 256-bit modulo secp256k1 order, so convert explicitly.
static inline void EncodeGpuDistanceSym(Int *dist, uint64_t *d0, uint64_t *d1, uint64_t *d2) {
  Int absDist(dist);
  if(absDist.IsZero()) {
    *d0 = 0ULL;
    *d1 = 0ULL;
    *d2 = 0ULL;
    return;
  }

  // Probability of failure (1/2^192): check bits 192+ for sign
  if(absDist.bits64[3] > 0x7FFFFFFFFFFFFFFFULL) {
    absDist.ModNegK1order();
    if(absDist.IsZero()) {
      *d0 = 0ULL;
      *d1 = 0ULL;
      *d2 = 0ULL;
      return;
    }
    *d0 = absDist.bits64[0];
    *d1 = absDist.bits64[1];
    *d2 = (absDist.bits64[2] & ~kGpuDistSignBit) | kGpuDistSignBit;
    return;
  }

  *d0 = absDist.bits64[0];
  *d1 = absDist.bits64[1];
  *d2 = absDist.bits64[2] & ~kGpuDistSignBit;
}

static inline void DecodeGpuDistanceSym(uint64_t d0, uint64_t d1, uint64_t d2, Int *dist) {
  dist->SetInt32(0);
  uint64_t mag2 = d2 & ~kGpuDistSignBit;
  dist->bits64[0] = d0;
  dist->bits64[1] = d1;
  dist->bits64[2] = mag2;
  if((d2 & kGpuDistSignBit) != 0ULL && (d0 != 0ULL || d1 != 0ULL || mag2 != 0ULL)) {
    dist->ModNegK1order();
  }
}
#endif

class GPUEngine {

public:

  GPUEngine(int nbThreadGroup,int nbThreadPerGroup,int gpuId,uint32_t maxFound);
  ~GPUEngine();
  void SetParams(uint64_t dpMask,Int *distance,Int *px,Int *py);
  void SetKangaroos(Int *px,Int *py,Int *d);
  void GetKangaroos(Int *px,Int *py,Int *d);
  void SetKangaroo(uint64_t kIdx,Int *px,Int *py,Int *d);
#ifdef WITHMETAL
  void SetKangaroos(Int *px,Int *py,Int *d,uint64_t *symClass);
  void GetKangaroos(Int *px,Int *py,Int *d,uint64_t *symClass);
  void SetKangaroo(uint64_t kIdx,Int *px,Int *py,Int *d,uint64_t symClass);
#endif
  bool Launch(std::vector<ITEM> &hashFound,bool spinWait = false);
  void SetWildOffset(Int *offset);
  int GetNbThread();
  int GetThreadsPerGroup() const { return nbThreadPerGroup; }
  int GetGroupSize();
  int GetMemory();
  bool callKernelAndWait();
  bool callKernel();
  int GetRunCount() const;
  int GetStateCacheMode() const;
  bool GetKangarooSymClass(uint64_t kIdx,uint64_t *symClass);

  std::string deviceName;

  static void *AllocatePinnedMemory(size_t size);
  static void FreePinnedMemory(void *buff);
  static void PrintCudaInfo();
  static bool GetGridSize(int gpuId,int *x,int *y);
  static bool RunUnitTests(int gpuId,int testCount);
  static int GetDefaultGroupSize();

private:

  Int wildOffset;
  int nbThread;
  int nbThreadPerGroup;
  uint64_t *inputKangaroo;
  uint64_t *inputKangarooPinned;
  uint32_t *outputItem;
  uint32_t *outputItemPinned;
  uint64_t *jumpPinned;
  bool initialised;
  bool lostWarning;
  uint32_t maxFound;
  uint32_t outputSize;
  uint32_t kangarooSize;
  uint32_t kangarooSizePinned;
  uint32_t jumpSize;
  uint64_t dpMask;
  int runCount;
  int groupSize;
  void *backendContext;

};

#endif // GPUENGINEH
