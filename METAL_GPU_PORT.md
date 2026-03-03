# Apple Metal GPU Backend for Kangaroo ECDLP Solver

This document describes the **Apple Metal GPU port** contributed to [keyhunt](https://github.com/albertobsd/keyhunt) — a complete GPU-accelerated backend that enables Pollard's kangaroo algorithm to run natively on Apple Silicon (and Intel Mac) GPUs via the Metal API.

## Motivation

Prior to this work, **all GPU-accelerated elliptic curve discrete logarithm (ECDLP) tools** in the Bitcoin/secp256k1 ecosystem — including Kangaroo, VanitySearch, BitCrack, and others — were **exclusively CUDA-only**. This hard dependency meant:

- Researchers and security auditors on macOS had **no GPU acceleration path**
- The growing Apple Silicon installed base was limited to CPU-only computation
- No open-source reference existed for 256-bit modular arithmetic on Metal shaders

This port eliminates these barriers, delivering **feature-complete GPU acceleration** on macOS with competitive performance.

## What Was Built

### Core Implementation (~5,000 lines)

| File | Lines | Description |
|------|------:|-------------|
| `Kangaroo/GPU/KangarooMetal.metal` | 3,192 | Metal shader: full secp256k1 arithmetic + kangaroo stepping |
| `Kangaroo/GPU/GPUEngineMetal.mm` | 1,750 | Objective-C++ host: pipeline management, buffer orchestration, profiling |

### Metal Shader (`KangarooMetal.metal`)

The shader implements, **entirely from scratch on Metal Shading Language**, the following:

- **256-bit unsigned integer arithmetic** — add, subtract, multiply, square, with carry propagation
- **Modular arithmetic over secp256k1's prime field** (p = 2²⁵⁶ − 2³² − 977)
  - Montgomery-style reduction using the constant `c = 0x1000003D1`
  - Specialized `reduce_c` path exploiting the sparse prime structure
- **Modular inversion** — direct Fermat's little theorem (a^(p-2) mod p) via optimized addition chain
- **Elliptic curve point operations** — affine point addition and doubling on secp256k1
- **Kangaroo stepping logic** — distinguished point (DP) detection, jump table lookups, collision reporting
- **Symmetry-aware search** (`USE_SYMMETRY`) — halves the search space by exploiting curve symmetry (y → -y)
- **Multiple compute modes** for performance tuning:
  - Mode 0: Full state cache (all kangaroo positions cached between dispatches)
  - Mode 1: No cache (minimal memory, recompute from distance each step)
  - Mode 2: Px-only cache
  - Mode 3: Distance-only cache
  - Mode 4: SIMD cooperative inversion (batched modular inverse across simdgroup lanes)
- **192-bit distance support** — extended from the original 128-bit to handle larger search ranges
- **SIMD intrinsics** — `simd_shuffle` / `simd_shuffle_up` / `simd_shuffle_down` for cross-lane data exchange in cooperative algorithms
- **Wide multiply strategies** — configurable 64×64→128 multiplication:
  - Native `mulhi` path for platforms with hardware wide-multiply
  - 32-bit piece decomposition fallback for broader compatibility

### Metal Host Engine (`GPUEngineMetal.mm`)

The Objective-C++ host layer manages:

- **Runtime shader compilation** with preprocessor macro injection (group size, symmetry, profiling flags)
- **Double-buffered command submission** — overlapped GPU execution and CPU result processing
- **Auto mode selection** — benchmarks mode 1 vs mode 4 at startup, selects the faster one
- **Configurable via environment variables** — no recompilation needed to tune:
  - `KANGAROO_METAL_GRP_SIZE` — threads per threadgroup (1–128)
  - `KANGAROO_METAL_NB_RUN` — steps per GPU dispatch (1–64)
  - `KANGAROO_METAL_STATE_CACHE_MODE` — select compute mode (0–5)
  - `KANGAROO_METAL_BLOCK_WAIT` — blocking vs polling command buffer wait
  - `KANGAROO_METAL_WAIT_TIMEOUT_MS` — GPU timeout threshold
  - `KANGAROO_METAL_PROFILE` / `KANGAROO_METAL_INV_PROFILE` — performance profiling
- **Shader path resolution** — auto-discovers `.metal` source relative to executable
- **GPU self-test** (`-check`) — validates Metal arithmetic against CPU reference implementation

### Build System

The `Kangaroo/Makefile` was extended to **auto-detect the platform**:

- On **Darwin** (macOS): `gpu=1` compiles the Metal backend (`GPUEngineMetal.mm` + runtime shader compilation of `KangarooMetal.metal`) and links against `-framework Metal -framework Foundation`
- On **Linux**: `gpu=1` compiles the CUDA backend (`GPUEngine.cu`) with `nvcc` as before
- `sym=1` enables `USE_SYMMETRY` for both backends
- Build mode tracking via stamp files prevents stale object reuse

```bash
# macOS (Metal)
make clean && make gpu=1 sym=1 -j8

# Linux (CUDA)
make clean && make gpu=1 ccap=86 -j8
```

### Tuning Scripts

Two sweep scripts for automated parameter search:

| Script | Purpose |
|--------|---------|
| `Kangaroo/scripts/metal_mode_sweep.sh` | Benchmark all state cache modes, find optimal |
| `Kangaroo/scripts/metal_dp_sweep.sh` | Sweep DP bit values, find speed/overhead sweet spot |

## Feature Parity with CUDA

| Feature | CUDA | Metal |
|---------|:----:|:-----:|
| GPU kangaroo stepping | ✅ | ✅ |
| Distinguished point detection | ✅ | ✅ |
| Symmetry mode (`USE_SYMMETRY`) | ✅ | ✅ |
| Work file save/resume (`-w`, `-ws`) | ✅ | ✅ |
| Work file merge (`-wm`, `-wmdir`) | ✅ | ✅ |
| Multi-GPU (`-gpuId`) | ✅ | ✅ |
| GPU self-test (`-check`) | ✅ | ✅ |
| Server/client distributed mode | ✅ | ✅ |
| Split work files (`-wsplit`) | ✅ | ✅ |
| 192-bit distance | — | ✅ |
| Multiple compute modes (0–5) | — | ✅ |
| Auto mode selection (mode 1 vs 4) | — | ✅ |
| Runtime env-var tuning | — | ✅ |
| Performance profiling counters | — | ✅ |

## Performance

Benchmarked on Puzzle #135 (134-bit ECDLP, symmetry mode):

| Device | Backend | Speed |
|--------|---------|------:|
| Apple M4 Max (40-core GPU) | **Metal** | **576+ MKeys/s** |
| Mid-range NVIDIA GPU | CUDA | ~600 MKeys/s |

The Metal backend achieves near-parity with CUDA on comparable-generation hardware.

## Building and Running

### Prerequisites (macOS)

- macOS 13+ (Ventura or later)
- Xcode Command Line Tools (`xcode-select --install`)

### Quick Start

```bash
# Clone
git clone https://github.com/zhaoanran8666/keyhunt_2.git
cd keyhunt_2/Kangaroo

# Build with Metal GPU + symmetry
make clean && make gpu=1 sym=1 -j8

# List GPUs
./kangaroo -l

# Run GPU self-test
./kangaroo -gpu -gpuId 0 -g 64,256 -check

# Solve a puzzle (example: puzzle 75)
./kangaroo -gpu -gpuId 0 -g 80,256 -d 14 -t 0 \
  -o puzzle75_result.txt puzzle75.txt
```

### Recommended Environment Variables

```bash
# Optimal settings for M4 Max (adjust for your hardware)
KANGAROO_METAL_GRP_SIZE=128 \
KANGAROO_METAL_NB_RUN=1 \
KANGAROO_METAL_BLOCK_WAIT=1 \
KANGAROO_METAL_WAIT_TIMEOUT_MS=8000 \
./kangaroo -gpu -gpuId 0 -g 80,256 -d 35 -t 0 \
  -w puzzle135.work -wi 1800 -ws -wt 15000 \
  -o puzzle135_result.txt puzzle135.txt
```

## Repository Structure (Key Changes)

```
keyhunt_2/
├── Kangaroo/
│   ├── GPU/
│   │   ├── KangarooMetal.metal   # [NEW] Metal GPU shader (3,192 lines)
│   │   ├── GPUEngineMetal.mm     # [NEW] Metal host engine (1,750 lines)
│   │   ├── GPUEngine.cu          # [UNCHANGED] CUDA backend
│   │   ├── GPUEngine.h           # [MODIFIED] Unified GPU interface
│   │   └── GPUCompute.h          # [MODIFIED] Shared GPU definitions
│   ├── Makefile                  # [MODIFIED] Auto-detect Darwin/Linux
│   ├── Kangaroo.cpp              # [MODIFIED] Integration with Metal engine
│   ├── Thread.cpp                # [MODIFIED] Metal GPU thread management
│   ├── Backup.cpp                # [MODIFIED] 192-bit distance serialization
│   ├── Check.cpp                 # [MODIFIED] Metal GPU validation
│   ├── scripts/
│   │   ├── metal_mode_sweep.sh   # [NEW] Mode benchmark script
│   │   └── metal_dp_sweep.sh    # [NEW] DP parameter sweep script
│   └── ...
└── ...
```

## Upstream

This is a fork of [albertobsd/keyhunt](https://github.com/albertobsd/keyhunt) (931★ / 621 forks). The upstream repository provides the CPU backend and CUDA GPU backend. All Metal-related code and modifications in the `Kangaroo/` directory are original work by this fork.

## License

This project follows the same license as the upstream keyhunt. The Kangaroo module is licensed under GPLv3 (see `Kangaroo/LICENSE.txt`).
