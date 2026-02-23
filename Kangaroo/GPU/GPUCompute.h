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

// CUDA Kernel main function

// -----------------------------------------------------------------------------------------

__device__ __forceinline__ bool IsZero256_4(const uint64_t a[4]) {
  return (a[0] | a[1] | a[2] | a[3]) == 0ULL;
}

#ifdef USE_SYMMETRY
__device__ __forceinline__ uint32_t JumpIndexSym(uint64_t x0, uint64_t symClass) {
  const uint32_t half = (NB_JUMP >> 1);
  const uint32_t local = ((uint32_t)x0) & (half - 1U);
  return local + half * (uint32_t)(symClass & 1ULL);
}

__device__ __forceinline__ uint32_t JumpNextSym(uint32_t j, uint64_t symClass) {
  const uint32_t half = (NB_JUMP >> 1);
  const uint32_t base = half * (uint32_t)(symClass & 1ULL);
  const uint32_t local = j - base;
  return base + ((local + 1U) & (half - 1U));
}
#endif

__device__ void ComputeKangaroos(uint64_t *kangaroos,uint32_t maxFound,uint32_t *out,uint64_t dpMask) {

  uint64_t px[GPU_GRP_SIZE][4];
  uint64_t py[GPU_GRP_SIZE][4];
  uint64_t dist[GPU_GRP_SIZE][3];
#ifdef USE_SYMMETRY
  uint64_t symClass[GPU_GRP_SIZE];
#endif

  uint64_t dx[GPU_GRP_SIZE][4];
  uint32_t jSel[GPU_GRP_SIZE];
  uint64_t dy[4];
  uint64_t rx[4];
  uint64_t ry[4];
  uint64_t _s[4];
  uint64_t _p[4];
  uint32_t jmp;

#ifdef USE_SYMMETRY
  LoadKangaroos(kangaroos,px,py,dist,symClass);
#else
  LoadKangaroos(kangaroos,px,py,dist);
#endif

  for(int run = 0; run < NB_RUN; run++) {

    __syncthreads();

    for(int g = 0; g < GPU_GRP_SIZE; g++) {
#ifdef USE_SYMMETRY
      jSel[g] = JumpIndexSym(px[g][0],symClass[g]);
#else
      jSel[g] = (uint32_t)px[g][0] & (NB_JUMP - 1);
#endif
      ModSub256(dx[g],px[g],jPx[jSel[g]]);
    }

    _ModInvGrouped(dx);

    __syncthreads();

    for(int g = 0; g < GPU_GRP_SIZE; g++) {

      jmp = jSel[g];
      uint64_t invUse[4];
      Load256(invUse,dx[g]);

      if(IsZero256_4(invUse)) {
#ifdef USE_SYMMETRY
        uint32_t jAlt = JumpNextSym(jmp,symClass[g]);
#else
        uint32_t jAlt = (jmp + 1U) & (NB_JUMP - 1);
#endif
        uint64_t dxAlt[4];
        ModSub256(dxAlt,px[g],jPx[jAlt]);
        if(IsZero256_4(dxAlt)) {
          continue;
        }
        uint64_t invAlt[5];
        Load256(invAlt,dxAlt);
        invAlt[4] = 0ULL;
        _ModInv(invAlt);
        if(_IsZero(invAlt)) {
          continue;
        }
        Load256(invUse,invAlt);
        jmp = jAlt;
      }

      ModSub256(dy,py[g],jPy[jmp]);
      _ModMult(_s,dy,invUse);
      _ModSqr(_p,_s);

      ModSub256(rx,_p,jPx[jmp]);
      ModSub256(rx,px[g]);

      ModSub256(ry,px[g],rx);
      _ModMult(ry,_s);
      ModSub256(ry,py[g]);

      Load256(px[g],rx);
      Load256(py[g],ry);

#ifdef USE_SYMMETRY
      DistAddSigned192(dist[g],jD[jmp]);
      if(ModPositive256(py[g])) {
        DistToggleSign192(dist[g]);
        symClass[g] ^= 1ULL;
      }
#else
      Add128(dist[g],jD[jmp]);
#endif

      if((px[g][3] & dpMask) == 0) {

        // Distinguished point
        uint32_t pos = atomicAdd(out,1);
        if(pos < maxFound) {
          uint64_t kIdx = (uint64_t)IDX + (uint64_t)g * (uint64_t)blockDim.x +
                          (uint64_t)blockIdx.x * ((uint64_t)blockDim.x * GPU_GRP_SIZE);
          OutputDP(px[g],dist[g],&kIdx);
        }

      }

    }

  }

#ifdef USE_SYMMETRY
  StoreKangaroos(kangaroos,px,py,dist,symClass);
#else
  StoreKangaroos(kangaroos,px,py,dist);
#endif

}
