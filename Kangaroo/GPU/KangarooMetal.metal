#include <metal_stdlib>

using namespace metal;

// Default off: on Apple M4 Max this path regressed throughput vs the
// 32-bit-piece implementation (see performance notes).
#ifndef KANGAROO_METAL_USE_NATIVE_WIDE_MUL
#define KANGAROO_METAL_USE_NATIVE_WIDE_MUL 0
#endif
#ifndef KANGAROO_METAL_USE_UNSIGNED_MULHI
#define KANGAROO_METAL_USE_UNSIGNED_MULHI 0
#endif

constant uint kItemSize32 = 16;
constant uint kNbJump = 32;

// Compile-time specialization knobs (injected by GPUEngineMetal via preprocessorMacros).
// Keep defaults so the shader still compiles standalone.
#ifndef KANGAROO_METAL_GRP_SIZE
#define KANGAROO_METAL_GRP_SIZE 32
#endif
#ifndef KANGAROO_METAL_NB_RUN
#define KANGAROO_METAL_NB_RUN 4
#endif
#ifndef KANGAROO_METAL_ENABLE_INV_PROFILE
#define KANGAROO_METAL_ENABLE_INV_PROFILE 0
#endif
#ifndef KANGAROO_METAL_USE_SYMMETRY
#define KANGAROO_METAL_USE_SYMMETRY 0
#endif
// kReduceC = 2^32 + 977 specialization.
// Keep switchable for A/B on different Metal compilers/devices.
#ifndef KANGAROO_METAL_SPECIALIZE_REDUCEC
#define KANGAROO_METAL_SPECIALIZE_REDUCEC 0
#endif

constant uint kGpuGroupSize = static_cast<uint>(KANGAROO_METAL_GRP_SIZE);
constant uint kNbRun = static_cast<uint>(KANGAROO_METAL_NB_RUN);
constant uint kSimdWidth = 32u;
constant uint kMaxCoopSimdGroups = 8u; // prototype path assumes <=256 threads/group.

constant uint kInvMode = 1u; // 0: divstep+fallback, 1: direct pow inversion
constant ulong kP0 = 0xFFFFFFFEFFFFFC2Full;
constant ulong kP1 = 0xFFFFFFFFFFFFFFFFull;
constant ulong kP2 = 0xFFFFFFFFFFFFFFFFull;
constant ulong kP3 = 0xFFFFFFFFFFFFFFFFull;
constant ulong kReduceC = 0x1000003D1ull;
#if KANGAROO_METAL_USE_SYMMETRY
constant ulong kOrder0 = 0xBFD25E8CD0364141ull;
constant ulong kOrder1 = 0xBAAEDCE6AF48A03Bull;
#endif

struct KernelParams {
  uint maxFound;
  uint nbThreadPerGroup;
  uint nbThreadGroup;
  uint nbRun;
  uint kSize;
  uint gpuGroupSize;
  uint profileMode;
  uint paramPad;       // 显式 padding，确保 dpMask 偏移与 C++ 端一致
  ulong dpMask;
};

struct MathTestInput {
  ulong a[4];
  ulong b[4];
  ulong px[4];
  ulong py[4];
  ulong jx[4];
  ulong jy[4];
};

struct MathTestOutput {
  ulong mul[4];
  ulong sqr[4];
  ulong inv[4];
  ulong rx[4];
  ulong ry[4];
  uint flags;
  uint pad;
};

inline uint lo32(ulong v) { return static_cast<uint>(v & 0xffffffffull); }
inline uint hi32(ulong v) { return static_cast<uint>(v >> 32); }
inline uint jump_index(ulong x0) { return static_cast<uint>(x0) & (kNbJump - 1u); }

#if KANGAROO_METAL_USE_SYMMETRY
inline uint jump_index_sym(ulong x0, uint symClass) {
  const uint halfRange = (kNbJump >> 1u);
  uint j = jump_index(x0) & (halfRange - 1u);
  return j + halfRange * (symClass & 1u);
}

inline uint jump_next_sym(uint j, uint symClass) {
  const uint halfRange = (kNbJump >> 1u);
  const uint base = halfRange * (symClass & 1u);
  const uint local = j - base;
  return base + ((local + 1u) & (halfRange - 1u));
}
#endif

inline ulong addcarry_u64(ulong a, ulong b, thread ulong &carry) {
  ulong sum = a + b;
  ulong out = sum + carry;
  carry = ((sum < a) || (out < sum)) ? 1ull : 0ull;
  return out;
}

inline ulong subborrow_u64(ulong a, ulong b, thread ulong &borrow) {
  ulong rhs = b + borrow;
  ulong rhsCarry = (rhs < b) ? 1ull : 0ull;
  ulong out = a - rhs;
  borrow = ((a < rhs) ? 1ull : 0ull) | rhsCarry;
  return out;
}

// 64x64 -> 128 with 32-bit pieces (portable and validated for current MSL path).
inline ulong2 mul64wide_u32(ulong a, ulong b) {
#if KANGAROO_METAL_USE_NATIVE_WIDE_MUL
#if KANGAROO_METAL_USE_UNSIGNED_MULHI
  // Prefer direct unsigned high-mul when compiler/target supports it well.
  return ulong2(a * b, mulhi(a, b));
#else
  long sa = as_type<long>(a);
  long sb = as_type<long>(b);
  ulong hi = as_type<ulong>(mulhi(sa, sb));
  ulong maskA = 0ull - (a >> 63);
  ulong maskB = 0ull - (b >> 63);
  hi += (maskA & b);
  hi += (maskB & a);
  return ulong2(a * b, hi);
#endif
#else
  uint a0 = static_cast<uint>(a & 0xffffffffull);
  uint a1 = static_cast<uint>(a >> 32);
  uint b0 = static_cast<uint>(b & 0xffffffffull);
  uint b1 = static_cast<uint>(b >> 32);

  ulong p00 = static_cast<ulong>(a0) * static_cast<ulong>(b0);
  ulong p01 = static_cast<ulong>(a0) * static_cast<ulong>(b1);
  ulong p10 = static_cast<ulong>(a1) * static_cast<ulong>(b0);
  ulong p11 = static_cast<ulong>(a1) * static_cast<ulong>(b1);

  ulong mid = (p00 >> 32) + (p01 & 0xffffffffull) + (p10 & 0xffffffffull);

  ulong2 out;
  out.x = (p00 & 0xffffffffull) | (mid << 32);
  out.y = p11 + (p01 >> 32) + (p10 >> 32) + (mid >> 32);
  return out;
#endif
}

inline ulong2 mul64wide_uconst_977(ulong a) {
  uint a0 = static_cast<uint>(a & 0xffffffffull);
  uint a1 = static_cast<uint>(a >> 32);
  ulong p0 = static_cast<ulong>(a0) * 977ull;
  ulong p1 = static_cast<ulong>(a1) * 977ull;

  ulong loShift = p1 << 32;
  ulong lo = p0 + loShift;
  ulong hi = (p1 >> 32) + ((lo < p0) ? 1ull : 0ull);
  return ulong2(lo, hi);
}

inline ulong2 mul_reduce_c_u64(ulong a) {
#if KANGAROO_METAL_SPECIALIZE_REDUCEC
  // a * (2^32 + 977) = (a << 32) + a*977
  ulong2 p = mul64wide_uconst_977(a);
  ulong carry = 0ull;
  ulong lo = addcarry_u64(p.x, (a << 32), carry);
  ulong hi = addcarry_u64(p.y, (a >> 32), carry);
  return ulong2(lo, hi);
#else
  return mul64wide_u32(a, kReduceC);
#endif
}

// Forward declaration for fallback path in mul256_reduce_c.
inline void mul256_u64(thread const ulong a[4], ulong b, thread ulong out[5]);

inline void mul256_reduce_c(thread const ulong a[4], thread ulong out[5]) {
#if KANGAROO_METAL_SPECIALIZE_REDUCEC
  ulong carry = 0ull;
  for(uint i = 0; i < 4; i++) {
    ulong2 p = mul64wide_uconst_977(a[i]);
    ulong sum = p.x + carry;
    ulong c = (sum < p.x) ? 1ull : 0ull;
    out[i] = sum;
    carry = p.y + c;
  }
  out[4] = carry;

  // Add (a << 32) on 64-bit limbs.
  carry = 0ull;
  out[0] = addcarry_u64(out[0], (a[0] << 32), carry);
  out[1] = addcarry_u64(out[1], (a[1] << 32) | (a[0] >> 32), carry);
  out[2] = addcarry_u64(out[2], (a[2] << 32) | (a[1] >> 32), carry);
  out[3] = addcarry_u64(out[3], (a[3] << 32) | (a[2] >> 32), carry);
  out[4] = addcarry_u64(out[4], (a[3] >> 32), carry);
#else
  mul256_u64(a, kReduceC, out);
#endif
}

inline long add_i64_wrap(long a, long b) {
  return as_type<long>(as_type<ulong>(a) + as_type<ulong>(b));
}

inline long sub_i64_wrap(long a, long b) {
  return as_type<long>(as_type<ulong>(a) - as_type<ulong>(b));
}

inline long neg_i64_wrap(long a) {
  return as_type<long>(0ull - as_type<ulong>(a));
}

inline long mulhi_signed_u64(ulong a, ulong b) {
  long sa = as_type<long>(a);
  long sb = as_type<long>(b);
  return mulhi(sa, sb);
}

inline ulong sleft128(ulong lo, ulong hi, uint n) {
  return (hi << n) | (lo >> (64u - n));
}

inline uint ctz64_nonzero(ulong x) {
  return static_cast<uint>(ctz(x));
}

inline void copy4(thread ulong dst[4], thread const ulong src[4]) {
  dst[0] = src[0];
  dst[1] = src[1];
  dst[2] = src[2];
  dst[3] = src[3];
}

inline void copy5(thread ulong dst[5], thread const ulong src[5]) {
  dst[0] = src[0];
  dst[1] = src[1];
  dst[2] = src[2];
  dst[3] = src[3];
  dst[4] = src[4];
}

inline void copy4_from_device(thread ulong dst[4], device const ulong *src) {
  dst[0] = src[0];
  dst[1] = src[1];
  dst[2] = src[2];
  dst[3] = src[3];
}

inline void copy4_from_constant(thread ulong dst[4], constant const ulong *src) {
  dst[0] = src[0];
  dst[1] = src[1];
  dst[2] = src[2];
  dst[3] = src[3];
}

inline void copy4_from_threadgroup(thread ulong dst[4], threadgroup const ulong src[4]) {
  dst[0] = src[0];
  dst[1] = src[1];
  dst[2] = src[2];
  dst[3] = src[3];
}

inline ulong simd_shuffle_u64(ulong v, ushort lane) {
  uint2 p = as_type<uint2>(v);
  p.x = simd_shuffle(p.x, lane);
  p.y = simd_shuffle(p.y, lane);
  return as_type<ulong>(p);
}

inline ulong simd_shuffle_up_u64(ulong v, ushort delta) {
  uint2 p = as_type<uint2>(v);
  p.x = simd_shuffle_up(p.x, delta);
  p.y = simd_shuffle_up(p.y, delta);
  return as_type<ulong>(p);
}

inline ulong simd_shuffle_down_u64(ulong v, ushort delta) {
  uint2 p = as_type<uint2>(v);
  p.x = simd_shuffle_down(p.x, delta);
  p.y = simd_shuffle_down(p.y, delta);
  return as_type<ulong>(p);
}

inline void simd_shuffle_up_256(thread ulong out[4], thread const ulong in[4], uint delta) {
  ushort d = static_cast<ushort>(delta);
  out[0] = simd_shuffle_up_u64(in[0], d);
  out[1] = simd_shuffle_up_u64(in[1], d);
  out[2] = simd_shuffle_up_u64(in[2], d);
  out[3] = simd_shuffle_up_u64(in[3], d);
}

inline void simd_shuffle_down_256(thread ulong out[4], thread const ulong in[4], uint delta) {
  ushort d = static_cast<ushort>(delta);
  out[0] = simd_shuffle_down_u64(in[0], d);
  out[1] = simd_shuffle_down_u64(in[1], d);
  out[2] = simd_shuffle_down_u64(in[2], d);
  out[3] = simd_shuffle_down_u64(in[3], d);
}

inline void simd_broadcast_256(thread ulong out[4], thread const ulong in[4], uint lane) {
  ushort l = static_cast<ushort>(lane);
  out[0] = simd_shuffle_u64(in[0], l);
  out[1] = simd_shuffle_u64(in[1], l);
  out[2] = simd_shuffle_u64(in[2], l);
  out[3] = simd_shuffle_u64(in[3], l);
}

inline void copy4_to_device(device ulong *dst, thread const ulong src[4]) {
  dst[0] = src[0];
  dst[1] = src[1];
  dst[2] = src[2];
  dst[3] = src[3];
}

inline bool is_zero_256(thread const ulong a[4]) {
  return (a[0] | a[1] | a[2] | a[3]) == 0ull;
}

inline bool is_one_256(thread const ulong a[4]) {
  return (a[0] == 1ull) && (a[1] == 0ull) && (a[2] == 0ull) && (a[3] == 0ull);
}

inline bool is_zero_320(thread const ulong a[5]) {
  return (a[0] | a[1] | a[2] | a[3] | a[4]) == 0ull;
}

inline bool is_one_320(thread const ulong a[5]) {
  return (a[0] == 1ull) && (a[1] == 0ull) && (a[2] == 0ull) && (a[3] == 0ull) &&
         (a[4] == 0ull);
}

inline bool is_negative_320(thread const ulong a[5]) {
  return as_type<long>(a[4]) < 0;
}

inline void set_one_256(thread ulong a[4]) {
  a[0] = 1ull;
  a[1] = 0ull;
  a[2] = 0ull;
  a[3] = 0ull;
}

inline void set_zero_256(thread ulong a[4]) {
  a[0] = 0ull;
  a[1] = 0ull;
  a[2] = 0ull;
  a[3] = 0ull;
}

inline void neg_320(thread ulong r[5]) {
  ulong borrow = 0ull;
  r[0] = subborrow_u64(0ull, r[0], borrow);
  r[1] = subborrow_u64(0ull, r[1], borrow);
  r[2] = subborrow_u64(0ull, r[2], borrow);
  r[3] = subborrow_u64(0ull, r[3], borrow);
  r[4] = subborrow_u64(0ull, r[4], borrow);
}

inline void add_p_320(thread ulong r[5]) {
  ulong carry = 0ull;
  r[0] = addcarry_u64(r[0], kP0, carry);
  r[1] = addcarry_u64(r[1], kP1, carry);
  r[2] = addcarry_u64(r[2], kP2, carry);
  r[3] = addcarry_u64(r[3], kP3, carry);
  r[4] = addcarry_u64(r[4], 0ull, carry);
}

inline void sub_p_320(thread ulong r[5]) {
  ulong borrow = 0ull;
  r[0] = subborrow_u64(r[0], kP0, borrow);
  r[1] = subborrow_u64(r[1], kP1, borrow);
  r[2] = subborrow_u64(r[2], kP2, borrow);
  r[3] = subborrow_u64(r[3], kP3, borrow);
  r[4] = subborrow_u64(r[4], 0ull, borrow);
}

inline void shift_r62_inplace(thread ulong r[5]) {
  r[0] = (r[1] << 2) | (r[0] >> 62);
  r[1] = (r[2] << 2) | (r[1] >> 62);
  r[2] = (r[3] << 2) | (r[2] >> 62);
  r[3] = (r[4] << 2) | (r[3] >> 62);
  r[4] = as_type<ulong>(as_type<long>(r[4]) >> 62);
}

inline void shift_r62_from(thread ulong dst[5], thread const ulong src[5], ulong carry) {
  dst[0] = (src[1] << 2) | (src[0] >> 62);
  dst[1] = (src[2] << 2) | (src[1] >> 62);
  dst[2] = (src[3] << 2) | (src[2] >> 62);
  dst[3] = (src[4] << 2) | (src[3] >> 62);
  dst[4] = (carry << 2) | (src[4] >> 62);
}

inline void add5_shifted(thread ulong accum[8], uint offset, thread const ulong addv[5]) {
  ulong carry = 0ull;
  for(uint i = 0; i < 5; i++) {
    uint idx = offset + i;
    ulong s1 = accum[idx] + addv[i];
    ulong c1 = (s1 < accum[idx]) ? 1ull : 0ull;
    ulong s2 = s1 + carry;
    ulong c2 = (s2 < s1) ? 1ull : 0ull;
    accum[idx] = s2;
    carry = (c1 | c2);
  }

  uint idx = offset + 5;
  while(carry != 0ull && idx < 8) {
    ulong oldv = accum[idx];
    ulong sum = oldv + carry;
    carry = (sum < oldv) ? 1ull : 0ull;
    accum[idx] = sum;
    idx++;
  }
}

inline void mul256_u64(thread const ulong a[4], ulong b, thread ulong out[5]) {
  ulong carry = 0ull;
  for(uint i = 0; i < 4; i++) {
    ulong2 p = mul64wide_u32(a[i], b);
    ulong sum = p.x + carry;
    ulong c = (sum < p.x) ? 1ull : 0ull;
    out[i] = sum;
    carry = p.y + c;
  }
  out[4] = carry;
}

inline void imult_320(thread ulong r[5], thread const ulong a[5], long b) {
  ulong t[5];
  ulong ub;
  if(b < 0) {
    copy5(t, a);
    neg_320(t);
    ub = static_cast<ulong>(neg_i64_wrap(b));
  } else {
    copy5(t, a);
    ub = static_cast<ulong>(b);
  }

  ulong2 p0 = mul64wide_u32(t[0], ub);
  ulong2 p1 = mul64wide_u32(t[1], ub);
  ulong2 p2 = mul64wide_u32(t[2], ub);
  ulong2 p3 = mul64wide_u32(t[3], ub);
  ulong2 p4 = mul64wide_u32(t[4], ub);

  r[0] = p0.x;
  ulong carry = 0ull;
  r[1] = addcarry_u64(p1.x, p0.y, carry);
  r[2] = addcarry_u64(p2.x, p1.y, carry);
  r[3] = addcarry_u64(p3.x, p2.y, carry);
  r[4] = addcarry_u64(p4.x, p3.y, carry);
}

inline ulong imultc_320(thread ulong r[5], thread const ulong a[5], long b) {
  ulong t[5];
  ulong ub;
  if(b < 0) {
    copy5(t, a);
    neg_320(t);
    ub = static_cast<ulong>(neg_i64_wrap(b));
  } else {
    copy5(t, a);
    ub = static_cast<ulong>(b);
  }

  ulong2 p0 = mul64wide_u32(t[0], ub);
  ulong2 p1 = mul64wide_u32(t[1], ub);
  ulong2 p2 = mul64wide_u32(t[2], ub);
  ulong2 p3 = mul64wide_u32(t[3], ub);
  ulong2 p4 = mul64wide_u32(t[4], ub);

  r[0] = p0.x;
  ulong carry = 0ull;
  r[1] = addcarry_u64(p1.x, p0.y, carry);
  r[2] = addcarry_u64(p2.x, p1.y, carry);
  r[3] = addcarry_u64(p3.x, p2.y, carry);
  r[4] = addcarry_u64(p4.x, p3.y, carry);

  long signedHigh = mulhi_signed_u64(t[4], ub);
  long carrySigned = add_i64_wrap(signedHigh, static_cast<long>(carry));
  return as_type<ulong>(carrySigned);
}

inline void matrix_vec_mul_half(thread ulong dest[5],
                                thread const ulong u[5],
                                thread const ulong v[5],
                                long _11,
                                long _12,
                                thread ulong &carry) {
  ulong t1[5];
  ulong t2[5];
  ulong c1 = imultc_320(t1, u, _11);
  ulong c2 = imultc_320(t2, v, _12);

  ulong addCarry = 0ull;
  dest[0] = addcarry_u64(t1[0], t2[0], addCarry);
  dest[1] = addcarry_u64(t1[1], t2[1], addCarry);
  dest[2] = addcarry_u64(t1[2], t2[2], addCarry);
  dest[3] = addcarry_u64(t1[3], t2[3], addCarry);
  dest[4] = addcarry_u64(t1[4], t2[4], addCarry);

  carry = c1 + c2 + addCarry;
}

inline void matrix_vec_mul(thread ulong u[5],
                           thread ulong v[5],
                           long _11,
                           long _12,
                           long _21,
                           long _22) {
  ulong t1[5];
  ulong t2[5];
  ulong t3[5];
  ulong t4[5];

  imult_320(t1, u, _11);
  imult_320(t2, v, _12);
  imult_320(t3, u, _21);
  imult_320(t4, v, _22);

  ulong carry = 0ull;
  u[0] = addcarry_u64(t1[0], t2[0], carry);
  u[1] = addcarry_u64(t1[1], t2[1], carry);
  u[2] = addcarry_u64(t1[2], t2[2], carry);
  u[3] = addcarry_u64(t1[3], t2[3], carry);
  u[4] = addcarry_u64(t1[4], t2[4], carry);

  carry = 0ull;
  v[0] = addcarry_u64(t3[0], t4[0], carry);
  v[1] = addcarry_u64(t3[1], t4[1], carry);
  v[2] = addcarry_u64(t3[2], t4[2], carry);
  v[3] = addcarry_u64(t3[3], t4[3], carry);
  v[4] = addcarry_u64(t3[4], t4[4], carry);
}

inline ulong add_ch(thread ulong r[5], thread const ulong a[5], ulong carryIn) {
  ulong carry = 0ull;
  r[0] = addcarry_u64(r[0], a[0], carry);
  r[1] = addcarry_u64(r[1], a[1], carry);
  r[2] = addcarry_u64(r[2], a[2], carry);
  r[3] = addcarry_u64(r[3], a[3], carry);
  r[4] = addcarry_u64(r[4], a[4], carry);
  return carryIn + carry;
}

inline void mul_p(thread ulong r[5], ulong a) {
  ulong2 p = mul_reduce_c_u64(a);
  ulong borrow = 0ull;
  r[0] = subborrow_u64(0ull, p.x, borrow);
  r[1] = subborrow_u64(0ull, p.y, borrow);
  r[2] = subborrow_u64(0ull, 0ull, borrow);
  r[3] = subborrow_u64(0ull, 0ull, borrow);
  r[4] = subborrow_u64(a, 0ull, borrow);
}

inline void divstep62(thread ulong u[5],
                      thread ulong v[5],
                      thread int &pos,
                      thread long &uu,
                      thread long &uv,
                      thread long &vu,
                      thread long &vv) {
  uu = 1;
  uv = 0;
  vu = 0;
  vv = 1;

  uint bitCount = 62u;
  ulong u0 = u[0];
  ulong v0 = v[0];
  ulong uh;
  ulong vh;

  while(pos > 0 && ((u[pos] | v[pos]) == 0ull)) {
    pos--;
  }

  if(pos == 0) {
    uh = u0;
    vh = v0;
  } else {
    uint s = static_cast<uint>(clz(u[pos] | v[pos]));
    if(s == 0u) {
      uh = u[pos];
      vh = v[pos];
    } else {
      uh = sleft128(u[pos - 1], u[pos], s);
      vh = sleft128(v[pos - 1], v[pos], s);
    }
  }

  uint guard = 0u;
  while(true) {
    guard++;
    if(guard > 192u) {
      // Safety net: force return if divstep degenerates.
      uu = 1;
      uv = 0;
      vu = 0;
      vv = 1;
      return;
    }

    uint zeros = ctz64_nonzero(v0 | (1ull << bitCount));

    v0 >>= zeros;
    vh >>= zeros;
    uu = as_type<long>(as_type<ulong>(uu) << zeros);
    uv = as_type<long>(as_type<ulong>(uv) << zeros);
    bitCount -= zeros;

    if(bitCount == 0u) {
      break;
    }

    if(vh < uh) {
      ulong tmpU = uh;
      uh = vh;
      vh = tmpU;

      tmpU = u0;
      u0 = v0;
      v0 = tmpU;

      long tmpS = uu;
      uu = vu;
      vu = tmpS;

      tmpS = uv;
      uv = vv;
      vv = tmpS;
    }

    vh -= uh;
    v0 -= u0;
    vv = sub_i64_wrap(vv, uv);
    vu = sub_i64_wrap(vu, uu);
  }
}

inline void mod_sub_256(thread ulong r[4], thread const ulong a[4], thread const ulong b[4]) {
  ulong borrow = 0ull;
  r[0] = subborrow_u64(a[0], b[0], borrow);
  r[1] = subborrow_u64(a[1], b[1], borrow);
  r[2] = subborrow_u64(a[2], b[2], borrow);
  r[3] = subborrow_u64(a[3], b[3], borrow);

  ulong mask = 0ull - borrow;
  ulong carry = 0ull;
  r[0] = addcarry_u64(r[0], kP0 & mask, carry);
  r[1] = addcarry_u64(r[1], kP1 & mask, carry);
  r[2] = addcarry_u64(r[2], kP2 & mask, carry);
  r[3] = addcarry_u64(r[3], kP3 & mask, carry);
}

inline void mod_add_256(thread ulong r[4], thread const ulong a[4], thread const ulong b[4]) {
  ulong carry = 0ull;
  ulong s0 = addcarry_u64(a[0], b[0], carry);
  ulong s1 = addcarry_u64(a[1], b[1], carry);
  ulong s2 = addcarry_u64(a[2], b[2], carry);
  ulong s3 = addcarry_u64(a[3], b[3], carry);

  ulong borrow = 0ull;
  ulong t0 = subborrow_u64(s0, kP0, borrow);
  ulong t1 = subborrow_u64(s1, kP1, borrow);
  ulong t2 = subborrow_u64(s2, kP2, borrow);
  ulong t3 = subborrow_u64(s3, kP3, borrow);

  // Reduce when sum overflowed 256 bits (carry=1) or sum >= p (borrow=0).
  ulong needReduce = carry | (1ull - borrow);
  ulong mask = 0ull - needReduce;

  r[0] = (s0 & ~mask) | (t0 & mask);
  r[1] = (s1 & ~mask) | (t1 & mask);
  r[2] = (s2 & ~mask) | (t2 & mask);
  r[3] = (s3 & ~mask) | (t3 & mask);
}

inline void mod_sub_256_tg(thread ulong r[4],
                           thread const ulong a[4],
                           threadgroup const ulong b[4]) {
  ulong borrow = 0ull;
  r[0] = subborrow_u64(a[0], b[0], borrow);
  r[1] = subborrow_u64(a[1], b[1], borrow);
  r[2] = subborrow_u64(a[2], b[2], borrow);
  r[3] = subborrow_u64(a[3], b[3], borrow);

  ulong mask = 0ull - borrow;
  ulong carry = 0ull;
  r[0] = addcarry_u64(r[0], kP0 & mask, carry);
  r[1] = addcarry_u64(r[1], kP1 & mask, carry);
  r[2] = addcarry_u64(r[2], kP2 & mask, carry);
  r[3] = addcarry_u64(r[3], kP3 & mask, carry);
}

#if KANGAROO_METAL_USE_SYMMETRY
inline void mod_neg_256(thread ulong r[4], thread const ulong a[4]) {
  ulong t0;
  ulong t1;
  ulong t2;
  ulong t3;
  ulong borrow = 0ull;
  t0 = subborrow_u64(0ull, a[0], borrow);
  t1 = subborrow_u64(0ull, a[1], borrow);
  t2 = subborrow_u64(0ull, a[2], borrow);
  t3 = subborrow_u64(0ull, a[3], borrow);

  ulong carry = 0ull;
  r[0] = addcarry_u64(t0, kP0, carry);
  r[1] = addcarry_u64(t1, kP1, carry);
  r[2] = addcarry_u64(t2, kP2, carry);
  r[3] = addcarry_u64(t3, kP3, carry);
}

inline bool mod_positive_256(thread ulong r[4]) {
  if(r[3] > 0x7FFFFFFFFFFFFFFFull) {
    ulong t[4];
    mod_neg_256(t, r);
    copy4(r, t);
    return true;
  }
  return false;
}

// ---- 符号位翻转方案（修复 GPU-CPU 距离编码不一致） ----
// GPU 端距离编码: bit 127 = 符号位 (0=正, 1=已取模负), bit 0-126 = 绝对值
// 对称翻转时仅翻转符号位，不做模运算，避免产生 ~128-bit 值与 CPU 端
// HashTable::Convert 的 sign/type 位编码冲突。
constant ulong kDistSignBit = (1ull << 63);  // d1 的 bit 63 = 全局 bit 127

// 有符号距离累加: d (sign-magnitude) += jmp (无符号正值)
// 正距离: |d| + jmp
// 负距离: 若 |d| >= jmp 则 |d| -= jmp (仍为负); 否则 |d| = jmp - |d| (变正)
inline void dist_add_signed_128(thread ulong &d0, thread ulong &d1,
                                 ulong jmp0, ulong jmp1) {
  ulong signBit = d1 & kDistSignBit;
  d1 &= ~kDistSignBit;  // 清除符号位得到绝对值

  if(signBit == 0ull) {
    // 正距离: 直接累加
    ulong carry = 0ull;
    d0 = addcarry_u64(d0, jmp0, carry);
    d1 = addcarry_u64(d1, jmp1, carry);
  } else {
    // 负距离: |d| - jmp
    ulong borrow = 0ull;
    ulong r0 = subborrow_u64(d0, jmp0, borrow);
    ulong r1 = subborrow_u64(d1, jmp1, borrow);
    if(borrow != 0ull) {
      // |d| < jmp: 结果变正, |result| = jmp - |d|
      borrow = 0ull;
      d0 = subborrow_u64(jmp0, d0, borrow);
      d1 = subborrow_u64(jmp1, d1, borrow);
      signBit = 0ull;
    } else {
      d0 = r0;
      d1 = r1;
    }
  }

  // Canonicalize signed zero to +0 to keep GPU/CPU reconstruction deterministic.
  if((d0 | d1) == 0ull) {
    signBit = 0ull;
  }

  d1 |= signBit;  // 恢复符号位
}

// 数组版本: dCache[g] 格式
inline void dist_add_signed_128(thread ulong d[2], ulong jmp0, ulong jmp1) {
  dist_add_signed_128(d[0], d[1], jmp0, jmp1);
}

inline void dist_toggle_sign_128(thread ulong &d0, thread ulong &d1) {
  if((d0 | (d1 & ~kDistSignBit)) == 0ull) {
    d1 = 0ull;
  } else {
    d1 ^= kDistSignBit;
  }
}

inline void dist_toggle_sign_128(thread ulong d[2]) {
  dist_toggle_sign_128(d[0], d[1]);
}

// 192-bit 有符号距离操作 (新格式: d[2] bit63=符号位, d[2] bits62-0+d[1]+d[0] = 190-bit量)
// jump 距离仅用 jmp0/jmp1 (≤67-bit), jmp2 隐式为 0

inline void dist_add_signed_192(thread ulong &d0, thread ulong &d1, thread ulong &d2,
                                 ulong jmp0, ulong jmp1) {
  ulong signBit = d2 & kDistSignBit;
  d2 &= ~kDistSignBit;  // 清除符号位，得到量的高位

  if(signBit == 0ull) {
    // 正距离: |d| += jmp
    ulong carry = 0ull;
    d0 = addcarry_u64(d0, jmp0, carry);
    d1 = addcarry_u64(d1, jmp1, carry);
    d2 = addcarry_u64(d2, 0ull, carry);
  } else {
    // 负距离: |d| -= jmp
    ulong borrow = 0ull;
    ulong r0 = subborrow_u64(d0, jmp0, borrow);
    ulong r1 = subborrow_u64(d1, jmp1, borrow);
    ulong r2 = subborrow_u64(d2, 0ull, borrow);
    if(borrow != 0ull) {
      // |d| < jmp: 结果变正, |result| = jmp - |d|
      borrow = 0ull;
      d0 = subborrow_u64(jmp0, d0, borrow);
      d1 = subborrow_u64(jmp1, d1, borrow);
      d2 = subborrow_u64(0ull, d2, borrow);
      signBit = 0ull;
    } else {
      d0 = r0;
      d1 = r1;
      d2 = r2;
    }
  }

  // 规范化符号零: +0
  if((d0 | d1 | d2) == 0ull) {
    signBit = 0ull;
  }

  d2 |= signBit;
}

// 数组版本: dCache[g] 格式 (3个元素)
inline void dist_add_signed_192(thread ulong d[3], ulong jmp0, ulong jmp1) {
  dist_add_signed_192(d[0], d[1], d[2], jmp0, jmp1);
}

inline void dist_toggle_sign_192(thread ulong &d0, thread ulong &d1, thread ulong &d2) {
  if((d0 | d1 | (d2 & ~kDistSignBit)) == 0ull) {
    d2 &= ~kDistSignBit;  // 规范化零为 +0
  } else {
    d2 ^= kDistSignBit;
  }
}

inline void dist_toggle_sign_192(thread ulong d[3]) {
  dist_toggle_sign_192(d[0], d[1], d[2]);
}
#endif

inline bool is_ge_p(thread const ulong a[4]) {
  if(a[3] != kP3) return a[3] > kP3;
  if(a[2] != kP2) return a[2] > kP2;
  if(a[1] != kP1) return a[1] > kP1;
  return a[0] >= kP0;
}

inline void sub_p(thread ulong a[4]) {
  ulong borrow = 0ull;
  a[0] = subborrow_u64(a[0], kP0, borrow);
  a[1] = subborrow_u64(a[1], kP1, borrow);
  a[2] = subborrow_u64(a[2], kP2, borrow);
  a[3] = subborrow_u64(a[3], kP3, borrow);
}

inline void mod_mul_k1(thread ulong r[4], thread const ulong a[4], thread const ulong b[4]) {
  ulong r512[8];
  r512[0] = r512[1] = r512[2] = r512[3] = 0ull;
  r512[4] = r512[5] = r512[6] = r512[7] = 0ull;

  ulong t[5];

  mul256_u64(a, b[0], t);
  r512[0] = t[0];
  r512[1] = t[1];
  r512[2] = t[2];
  r512[3] = t[3];
  r512[4] = t[4];

  mul256_u64(a, b[1], t);
  add5_shifted(r512, 1, t);

  mul256_u64(a, b[2], t);
  add5_shifted(r512, 2, t);

  mul256_u64(a, b[3], t);
  add5_shifted(r512, 3, t);

  // Reduce 512 -> 320
  ulong hi4[4] = {r512[4], r512[5], r512[6], r512[7]};
  mul256_reduce_c(hi4, t);

  ulong carry = 0ull;
  r512[0] = addcarry_u64(r512[0], t[0], carry);
  r512[1] = addcarry_u64(r512[1], t[1], carry);
  r512[2] = addcarry_u64(r512[2], t[2], carry);
  r512[3] = addcarry_u64(r512[3], t[3], carry);

  // Reduce 320 -> 256
  ulong extra = t[4] + carry;
  ulong2 fold = mul_reduce_c_u64(extra);

  carry = 0ull;
  r[0] = addcarry_u64(r512[0], fold.x, carry);
  r[1] = addcarry_u64(r512[1], fold.y, carry);
  r[2] = addcarry_u64(r512[2], 0ull, carry);
  r[3] = addcarry_u64(r512[3], 0ull, carry);
}

inline void mod_sqr_k1(thread ulong r[4], thread const ulong a[4]) {
  ulong r512[8];
  r512[5] = 0ull;
  r512[6] = 0ull;
  r512[7] = 0ull;

  ulong SL;
  ulong SH;

  ulong r01L;
  ulong r01H;
  ulong r02L;
  ulong r02H;
  ulong r03L;
  ulong r03H;

  ulong2 p = mul64wide_u32(a[0], a[0]);
  SL = p.x;
  SH = p.y;
  p = mul64wide_u32(a[0], a[1]);
  r01L = p.x;
  r01H = p.y;
  p = mul64wide_u32(a[0], a[2]);
  r02L = p.x;
  r02H = p.y;
  p = mul64wide_u32(a[0], a[3]);
  r03L = p.x;
  r03H = p.y;

  r512[0] = SL;
  r512[1] = r01L;
  r512[2] = r02L;
  r512[3] = r03L;

  ulong carry = 0ull;
  r512[1] = addcarry_u64(r512[1], SH, carry);
  r512[2] = addcarry_u64(r512[2], r01H, carry);
  r512[3] = addcarry_u64(r512[3], r02H, carry);
  r512[4] = addcarry_u64(r03H, 0ull, carry);

  ulong r12L;
  ulong r12H;
  ulong r13L;
  ulong r13H;

  p = mul64wide_u32(a[1], a[1]);
  SL = p.x;
  SH = p.y;
  p = mul64wide_u32(a[1], a[2]);
  r12L = p.x;
  r12H = p.y;
  p = mul64wide_u32(a[1], a[3]);
  r13L = p.x;
  r13H = p.y;

  carry = 0ull;
  r512[1] = addcarry_u64(r512[1], r01L, carry);
  r512[2] = addcarry_u64(r512[2], SL, carry);
  r512[3] = addcarry_u64(r512[3], r12L, carry);
  r512[4] = addcarry_u64(r512[4], r13L, carry);
  r512[5] = addcarry_u64(r13H, 0ull, carry);

  carry = 0ull;
  r512[2] = addcarry_u64(r512[2], r01H, carry);
  r512[3] = addcarry_u64(r512[3], SH, carry);
  r512[4] = addcarry_u64(r512[4], r12H, carry);
  r512[5] = addcarry_u64(r512[5], 0ull, carry);

  ulong r23L;
  ulong r23H;

  p = mul64wide_u32(a[2], a[2]);
  SL = p.x;
  SH = p.y;
  p = mul64wide_u32(a[2], a[3]);
  r23L = p.x;
  r23H = p.y;

  carry = 0ull;
  r512[2] = addcarry_u64(r512[2], r02L, carry);
  r512[3] = addcarry_u64(r512[3], r12L, carry);
  r512[4] = addcarry_u64(r512[4], SL, carry);
  r512[5] = addcarry_u64(r512[5], r23L, carry);
  r512[6] = addcarry_u64(r23H, 0ull, carry);

  carry = 0ull;
  r512[3] = addcarry_u64(r512[3], r02H, carry);
  r512[4] = addcarry_u64(r512[4], r12H, carry);
  r512[5] = addcarry_u64(r512[5], SH, carry);
  r512[6] = addcarry_u64(r512[6], 0ull, carry);

  p = mul64wide_u32(a[3], a[3]);
  SL = p.x;
  SH = p.y;

  carry = 0ull;
  r512[3] = addcarry_u64(r512[3], r03L, carry);
  r512[4] = addcarry_u64(r512[4], r13L, carry);
  r512[5] = addcarry_u64(r512[5], r23L, carry);
  r512[6] = addcarry_u64(r512[6], SL, carry);
  r512[7] = addcarry_u64(SH, 0ull, carry);

  carry = 0ull;
  r512[4] = addcarry_u64(r512[4], r03H, carry);
  r512[5] = addcarry_u64(r512[5], r13H, carry);
  r512[6] = addcarry_u64(r512[6], r23H, carry);
  r512[7] = addcarry_u64(r512[7], 0ull, carry);

  ulong t[5];
  ulong hi4[4] = {r512[4], r512[5], r512[6], r512[7]};
  mul256_reduce_c(hi4, t);

  carry = 0ull;
  r512[0] = addcarry_u64(r512[0], t[0], carry);
  r512[1] = addcarry_u64(r512[1], t[1], carry);
  r512[2] = addcarry_u64(r512[2], t[2], carry);
  r512[3] = addcarry_u64(r512[3], t[3], carry);

  ulong extra = t[4] + carry;
  ulong2 fold = mul_reduce_c_u64(extra);

  carry = 0ull;
  r[0] = addcarry_u64(r512[0], fold.x, carry);
  r[1] = addcarry_u64(r512[1], fold.y, carry);
  r[2] = addcarry_u64(r512[2], 0ull, carry);
  r[3] = addcarry_u64(r512[3], 0ull, carry);
}

inline void mod_sqr_n_k1(thread ulong out[4], thread const ulong in[4], uint n) {
  if(n == 0u) {
    copy4(out, in);
    return;
  }
  mod_sqr_k1(out, in);
  for(uint i = 1u; i < n; i++) {
    mod_sqr_k1(out, out);
  }
}

inline void mod_inv_pow_k1(thread ulong r[4], thread const ulong a[4]) {
  if(is_zero_256(a)) {
    set_zero_256(r);
    return;
  }

  // Dedicated secp256k1 addition-chain inversion.
  // Source chain reference:
  // https://briansmith.org/ecc-inversion-addition-chains-01
  // (secp256k1 field inversion chain by Peter Dettman)
  ulong x1[4];
  ulong x2[4];
  ulong x3[4];
  ulong x11[4];
  ulong x22[4];
  ulong x44[4];
  ulong x88[4];
  ulong t[4];

  copy4(x1, a);

  // x2 = x^(2^2-1) = x^3
  mod_sqr_k1(t, x1);
  mod_mul_k1(x2, t, x1);

  // x3 = x^(2^3-1) = x^7
  mod_sqr_k1(t, x2);
  mod_mul_k1(x3, t, x1);

  // x11 = x^(2^11-1)
  mod_sqr_n_k1(t, x3, 3u);
  mod_mul_k1(t, t, x3);
  mod_sqr_n_k1(t, t, 3u);
  mod_mul_k1(t, t, x3);
  mod_sqr_n_k1(t, t, 2u);
  mod_mul_k1(x11, t, x2);

  // x22, x44, x88
  mod_sqr_n_k1(t, x11, 11u);
  mod_mul_k1(x22, t, x11);
  mod_sqr_n_k1(t, x22, 22u);
  mod_mul_k1(x44, t, x22);
  mod_sqr_n_k1(t, x44, 44u);
  mod_mul_k1(x88, t, x44);

  // Build x^(p-3) then multiply by x to get x^(p-2).
  mod_sqr_n_k1(t, x88, 88u);
  mod_mul_k1(t, t, x88);
  mod_sqr_n_k1(t, t, 44u);
  mod_mul_k1(t, t, x44);
  mod_sqr_n_k1(t, t, 3u);
  mod_mul_k1(t, t, x3);
  mod_sqr_n_k1(t, t, 23u);
  mod_mul_k1(t, t, x22);
  mod_sqr_n_k1(t, t, 5u);
  mod_mul_k1(t, t, x1);
  mod_sqr_n_k1(t, t, 3u);
  mod_mul_k1(t, t, x2);
  mod_sqr_n_k1(t, t, 2u); // x^(p-3)
  mod_mul_k1(r, t, x1); // x^(p-2)
}

inline void mod_inv_divstep_k1(thread ulong r[4],
                               thread const ulong a[4],
                               thread uint &iterOut,
                               thread uint &fallbackOut,
                               thread uint &fallbackReasonOut) {
  // Placeholder for future exact divstep port.
  iterOut = 0u;
  fallbackOut = 1u;
  fallbackReasonOut = 1u;
  if(is_zero_256(a)) {
    set_zero_256(r);
    fallbackOut = 0u;
    fallbackReasonOut = 0u;
    return;
  }
  mod_inv_pow_k1(r, a);
}

inline void mod_inv_k1(thread ulong r[4],
                       thread const ulong a[4],
                       thread uint &iterOut,
                       thread uint &fallbackOut,
                       thread uint &fallbackReasonOut) {
  if(kInvMode != 0u) {
    mod_inv_pow_k1(r, a);
    iterOut = 0u;
    fallbackOut = 0u;
    fallbackReasonOut = 0u;
    return;
  }
  mod_inv_divstep_k1(r, a, iterOut, fallbackOut, fallbackReasonOut);
}

inline uint inv_factor_masked(thread ulong out[4], thread const ulong in[4]) {
  if(is_zero_256(in)) {
    set_one_256(out);
    return 1u;
  }
  copy4(out, in);
  return 0u;
}

inline void mod_inv_grouped_prefix_zero_safe(thread ulong vals[kGpuGroupSize][4],
                                             thread ulong prefix[kGpuGroupSize][4],
                                             thread uint zeroMask[kGpuGroupSize]) {
  ulong factor[4];
  zeroMask[0] = inv_factor_masked(factor, vals[0]);
  copy4(prefix[0], factor);

  for(uint i = 1; i < kGpuGroupSize; i++) {
    zeroMask[i] = inv_factor_masked(factor, vals[i]);
    ulong tmp[4];
    mod_mul_k1(tmp, prefix[i - 1u], factor);
    copy4(prefix[i], tmp);
  }
}

inline void mod_inv_grouped_scatter_zero_safe(thread ulong vals[kGpuGroupSize][4],
                                              thread ulong prefix[kGpuGroupSize][4],
                                              thread ulong inv[4],
                                              thread uint zeroMask[kGpuGroupSize]) {
  for(int i = static_cast<int>(kGpuGroupSize) - 1; i > 0; i--) {
    ulong newVal[4];
    mod_mul_k1(newVal, prefix[i - 1], inv);

    ulong factor[4];
    if(zeroMask[i] != 0u) {
      set_one_256(factor);
    } else {
      copy4(factor, vals[i]);
    }
    mod_mul_k1(inv, inv, factor);

    if(zeroMask[i] != 0u) {
      set_zero_256(vals[i]);
    } else {
      copy4(vals[i], newVal);
    }
  }

  if(zeroMask[0] != 0u) {
    set_zero_256(vals[0]);
  } else {
    copy4(vals[0], inv);
  }
}

#if KANGAROO_METAL_ENABLE_INV_PROFILE
inline void mod_inv_grouped(thread ulong vals[kGpuGroupSize][4],
                            thread ulong prefix[kGpuGroupSize][4],
                            thread uint &invCalls,
                            thread uint &invFallback,
                            thread uint &invIterSum,
                            thread uint &invIterMax,
                            thread uint &invFallbackIterLimit,
                            thread uint &invFallbackGcd,
                            thread uint &invFallbackNormNeg,
                            thread uint &invFallbackNormPos) {
  uint zeroMask[kGpuGroupSize];
  mod_inv_grouped_prefix_zero_safe(vals, prefix, zeroMask);

  ulong inv[4];
  copy4(inv, prefix[kGpuGroupSize - 1u]);
  uint invIter = 0u;
  uint invFallbackNow = 0u;
  uint invFallbackReason = 0u;
  mod_inv_k1(inv, inv, invIter, invFallbackNow, invFallbackReason);
  invCalls += 1u;
  invFallback += invFallbackNow;
  invIterSum += invIter;
  if(invIter > invIterMax) {
    invIterMax = invIter;
  }
  if(invFallbackNow != 0u) {
    if(invFallbackReason == 1u) {
      invFallbackIterLimit += 1u;
    } else if(invFallbackReason == 2u) {
      invFallbackGcd += 1u;
    } else if(invFallbackReason == 3u) {
      invFallbackNormNeg += 1u;
    } else if(invFallbackReason == 4u) {
      invFallbackNormPos += 1u;
    }
  }
  mod_inv_grouped_scatter_zero_safe(vals, prefix, inv, zeroMask);
}

inline void mod_inv_grouped_simd(thread ulong vals[kGpuGroupSize][4],
                                 thread ulong prefix[kGpuGroupSize][4],
                                 uint simdLane,
                                 thread uint &invCalls,
                                 thread uint &invFallback,
                                 thread uint &invIterSum,
                                 thread uint &invIterMax,
                                 thread uint &invFallbackIterLimit,
                                 thread uint &invFallbackGcd,
                                 thread uint &invFallbackNormNeg,
                                 thread uint &invFallbackNormPos) {
  uint zeroMask[kGpuGroupSize];
  mod_inv_grouped_prefix_zero_safe(vals, prefix, zeroMask);

  ulong laneProd[4];
  copy4(laneProd, prefix[kGpuGroupSize - 1u]);

  ulong prefIncl[4];
  copy4(prefIncl, laneProd);
  for(uint offset = 1u; offset < kSimdWidth; offset <<= 1u) {
    ulong up[4];
    simd_shuffle_up_256(up, prefIncl, offset);
    if(simdLane >= offset) {
      mod_mul_k1(prefIncl, prefIncl, up);
    }
  }

  ulong suffIncl[4];
  copy4(suffIncl, laneProd);
  for(uint offset = 1u; offset < kSimdWidth; offset <<= 1u) {
    ulong down[4];
    simd_shuffle_down_256(down, suffIncl, offset);
    if((simdLane + offset) < kSimdWidth) {
      mod_mul_k1(suffIncl, suffIncl, down);
    }
  }

  ulong invAll[4];
  simd_broadcast_256(invAll, prefIncl, kSimdWidth - 1u);
  if(simdLane == (kSimdWidth - 1u)) {
    uint invIter = 0u;
    uint invFallbackNow = 0u;
    uint invFallbackReason = 0u;
    mod_inv_k1(invAll, invAll, invIter, invFallbackNow, invFallbackReason);
    invCalls += 1u;
    invFallback += invFallbackNow;
    invIterSum += invIter;
    if(invIter > invIterMax) {
      invIterMax = invIter;
    }
    if(invFallbackNow != 0u) {
      if(invFallbackReason == 1u) {
        invFallbackIterLimit += 1u;
      } else if(invFallbackReason == 2u) {
        invFallbackGcd += 1u;
      } else if(invFallbackReason == 3u) {
        invFallbackNormNeg += 1u;
      } else if(invFallbackReason == 4u) {
        invFallbackNormPos += 1u;
      }
    }
  }
  simd_broadcast_256(invAll, invAll, kSimdWidth - 1u);

  ulong prefExcl[4];
  if(simdLane == 0u) {
    set_one_256(prefExcl);
  } else {
    simd_shuffle_up_256(prefExcl, prefIncl, 1u);
  }

  ulong suffExcl[4];
  if(simdLane == (kSimdWidth - 1u)) {
    set_one_256(suffExcl);
  } else {
    simd_shuffle_down_256(suffExcl, suffIncl, 1u);
  }

  ulong inv[4];
  mod_mul_k1(inv, prefExcl, suffExcl);
  mod_mul_k1(inv, inv, invAll);
  mod_inv_grouped_scatter_zero_safe(vals, prefix, inv, zeroMask);
}
#else
inline void mod_inv_grouped(thread ulong vals[kGpuGroupSize][4],
                            thread ulong prefix[kGpuGroupSize][4]) {
  uint zeroMask[kGpuGroupSize];
  mod_inv_grouped_prefix_zero_safe(vals, prefix, zeroMask);

  ulong inv[4];
  copy4(inv, prefix[kGpuGroupSize - 1u]);
  mod_inv_pow_k1(inv, inv);
  mod_inv_grouped_scatter_zero_safe(vals, prefix, inv, zeroMask);
}

inline void mod_inv_grouped_simd(thread ulong vals[kGpuGroupSize][4],
                                 thread ulong prefix[kGpuGroupSize][4],
                                 uint simdLane) {
  uint zeroMask[kGpuGroupSize];
  mod_inv_grouped_prefix_zero_safe(vals, prefix, zeroMask);

  ulong laneProd[4];
  copy4(laneProd, prefix[kGpuGroupSize - 1u]);

  ulong prefIncl[4];
  copy4(prefIncl, laneProd);
  for(uint offset = 1u; offset < kSimdWidth; offset <<= 1u) {
    ulong up[4];
    simd_shuffle_up_256(up, prefIncl, offset);
    if(simdLane >= offset) {
      mod_mul_k1(prefIncl, prefIncl, up);
    }
  }

  ulong suffIncl[4];
  copy4(suffIncl, laneProd);
  for(uint offset = 1u; offset < kSimdWidth; offset <<= 1u) {
    ulong down[4];
    simd_shuffle_down_256(down, suffIncl, offset);
    if((simdLane + offset) < kSimdWidth) {
      mod_mul_k1(suffIncl, suffIncl, down);
    }
  }

  ulong invAll[4];
  simd_broadcast_256(invAll, prefIncl, kSimdWidth - 1u);
  if(simdLane == (kSimdWidth - 1u)) {
    mod_inv_pow_k1(invAll, invAll);
  }
  simd_broadcast_256(invAll, invAll, kSimdWidth - 1u);

  ulong prefExcl[4];
  if(simdLane == 0u) {
    set_one_256(prefExcl);
  } else {
    simd_shuffle_up_256(prefExcl, prefIncl, 1u);
  }

  ulong suffExcl[4];
  if(simdLane == (kSimdWidth - 1u)) {
    set_one_256(suffExcl);
  } else {
    simd_shuffle_down_256(suffExcl, suffIncl, 1u);
  }

  ulong inv[4];
  mod_mul_k1(inv, prefExcl, suffExcl);
  mod_mul_k1(inv, inv, invAll);
  mod_inv_grouped_scatter_zero_safe(vals, prefix, inv, zeroMask);
}
#endif

inline void point_add_affine(thread ulong rx[4],
                             thread ulong ry[4],
                             thread const ulong x[4],
                             thread const ulong y[4],
                             thread const ulong jx[4],
                             thread const ulong jy[4],
                             thread const ulong dxInv[4]) {
  ulong dy[4];
  ulong s[4];
  ulong p[4];
  ulong t[4];

  mod_sub_256(dy, y, jy);
  mod_mul_k1(s, dy, dxInv);
  mod_sqr_k1(p, s);

  mod_sub_256(t, p, jx);
  mod_sub_256(rx, t, x);

  mod_sub_256(t, x, rx);
  mod_mul_k1(ry, t, s);
  mod_sub_256(ry, ry, y);
}

inline void point_add_affine_tg(thread ulong rx[4],
                                thread ulong ry[4],
                                thread const ulong x[4],
                                thread const ulong y[4],
                                threadgroup const ulong jx[4],
                                threadgroup const ulong jy[4],
                                thread const ulong dxInv[4]) {
  // Hot path: keep temporary field elements minimal to reduce register pressure.
  ulong s[4];
  ulong t[4];

  mod_sub_256_tg(t, y, jy);    // t = y2 - y1
  mod_mul_k1(s, t, dxInv);     // s = (y2 - y1)/(x2 - x1)
  mod_sqr_k1(t, s);            // t = s^2
  mod_sub_256_tg(t, t, jx);    // t = s^2 - x2
  mod_sub_256(rx, t, x);       // rx = s^2 - x1 - x2

  mod_sub_256(t, x, rx);       // t = x1 - rx
  mod_mul_k1(ry, t, s);        // ry = s*(x1-rx)
  mod_sub_256(ry, ry, y);
}

inline void point_add_mixed_jacobian_tg(thread ulong rx[4],
                                        thread ulong ry[4],
                                        thread ulong rz[4],
                                        thread const ulong x1[4],
                                        thread const ulong y1[4],
                                        thread const ulong z1[4],
                                        threadgroup const ulong jxTg[4],
                                        threadgroup const ulong jyTg[4]) {
  // Jacobian (X1,Y1,Z1) + affine (x2,y2), no field inversion in the add itself.
  // Prototype path: prefer explicit algebra over extra temporary caches.
  ulong jx[4];
  ulong jy[4];
  copy4_from_threadgroup(jx, jxTg);
  copy4_from_threadgroup(jy, jyTg);

  ulong z1z1[4];
  mod_sqr_k1(z1z1, z1);

  ulong u2[4];
  mod_mul_k1(u2, jx, z1z1);

  ulong z1z1z1[4];
  mod_mul_k1(z1z1z1, z1z1, z1);

  ulong s2[4];
  mod_mul_k1(s2, jy, z1z1z1);

  ulong h[4];
  mod_sub_256(h, u2, x1);

  ulong hh[4];
  mod_sqr_k1(hh, h);

  ulong i[4];
  mod_add_256(i, hh, hh);
  mod_add_256(i, i, i); // 4*HH

  ulong j[4];
  mod_mul_k1(j, h, i);

  ulong r2[4];
  mod_sub_256(r2, s2, y1);
  mod_add_256(r2, r2, r2); // 2*(S2-Y1)

  ulong v[4];
  mod_mul_k1(v, x1, i);

  ulong x3[4];
  mod_sqr_k1(x3, r2);
  mod_sub_256(x3, x3, j);
  ulong twoV[4];
  mod_add_256(twoV, v, v);
  mod_sub_256(x3, x3, twoV);

  ulong y3[4];
  ulong vMinusX3[4];
  mod_sub_256(vMinusX3, v, x3);
  mod_mul_k1(y3, r2, vMinusX3);
  ulong y1j[4];
  mod_mul_k1(y1j, y1, j);
  ulong twoY1J[4];
  mod_add_256(twoY1J, y1j, y1j);
  mod_sub_256(y3, y3, twoY1J);

  ulong z3[4];
  ulong z1PlusH[4];
  mod_add_256(z1PlusH, z1, h);
  mod_sqr_k1(z3, z1PlusH);
  mod_sub_256(z3, z3, z1z1);
  mod_sub_256(z3, z3, hh);

  copy4(rx, x3);
  copy4(ry, y3);
  copy4(rz, z3);
}

kernel void kangaroo_step(device ulong *kangaroos [[buffer(0)]],
                          device uint *outWords [[buffer(1)]],
                          constant ulong2 *jumpD [[buffer(2)]],
                          constant ulong4 *jumpX [[buffer(3)]],
                          constant ulong4 *jumpY [[buffer(4)]],
                          constant KernelParams &params [[buffer(5)]],
                          device atomic_uint *invProfile [[buffer(6)]],
                          uint localTid [[thread_position_in_threadgroup]],
                          uint groupId [[threadgroup_position_in_grid]]) {

  if(localTid >= params.nbThreadPerGroup || groupId >= params.nbThreadGroup) {
    return;
  }

  threadgroup ulong tgJumpD[kNbJump][2];
  threadgroup ulong tgJumpX[kNbJump][4];
  threadgroup ulong tgJumpY[kNbJump][4];

  if(localTid < kNbJump) {
    ulong2 d = jumpD[localTid];
    ulong4 x = jumpX[localTid];
    ulong4 y = jumpY[localTid];

    tgJumpD[localTid][0] = d.x;
    tgJumpD[localTid][1] = d.y;

    tgJumpX[localTid][0] = x.x;
    tgJumpX[localTid][1] = x.y;
    tgJumpX[localTid][2] = x.z;
    tgJumpX[localTid][3] = x.w;

    tgJumpY[localTid][0] = y.x;
    tgJumpY[localTid][1] = y.y;
    tgJumpY[localTid][2] = y.z;
    tgJumpY[localTid][3] = y.w;
  }

  threadgroup_barrier(mem_flags::mem_threadgroup);

  const uint blockSize = params.nbThreadPerGroup * params.kSize * kGpuGroupSize;
  const uint strideSize = params.nbThreadPerGroup * params.kSize;
  const uint blockBase = groupId * blockSize;

  device atomic_uint *counter = reinterpret_cast<device atomic_uint *>(outWords);

  thread ulong pxCache[kGpuGroupSize][4];
  thread ulong pyCache[kGpuGroupSize][4];
  thread ulong dCache[kGpuGroupSize][3];
  thread ulong dxInv[kGpuGroupSize][4];
  thread ulong prefix[kGpuGroupSize][4];
#if KANGAROO_METAL_USE_SYMMETRY
  thread uint symClassCache[kGpuGroupSize];
#endif
#if KANGAROO_METAL_ENABLE_INV_PROFILE
  uint invCalls = 0u;
  uint invFallback = 0u;
  uint invIterSum = 0u;
  uint invIterMax = 0u;
  uint invFallbackIterLimit = 0u;
  uint invFallbackGcd = 0u;
  uint invFallbackNormNeg = 0u;
  uint invFallbackNormPos = 0u;
#endif

  // Load kangaroo state once. Keep all nbRun iterations in thread-local cache.
  for(uint g = 0; g < kGpuGroupSize; g++) {
    const uint stride = g * strideSize;
    const uint idx0 = blockBase + stride + localTid;

    pxCache[g][0] = kangaroos[idx0 + 0u * params.nbThreadPerGroup];
    pxCache[g][1] = kangaroos[idx0 + 1u * params.nbThreadPerGroup];
    pxCache[g][2] = kangaroos[idx0 + 2u * params.nbThreadPerGroup];
    pxCache[g][3] = kangaroos[idx0 + 3u * params.nbThreadPerGroup];

    pyCache[g][0] = kangaroos[idx0 + 4u * params.nbThreadPerGroup];
    pyCache[g][1] = kangaroos[idx0 + 5u * params.nbThreadPerGroup];
    pyCache[g][2] = kangaroos[idx0 + 6u * params.nbThreadPerGroup];
    pyCache[g][3] = kangaroos[idx0 + 7u * params.nbThreadPerGroup];

    dCache[g][0] = kangaroos[idx0 + 8u * params.nbThreadPerGroup];
    dCache[g][1] = kangaroos[idx0 + 9u * params.nbThreadPerGroup];
    dCache[g][2] = kangaroos[idx0 + 10u * params.nbThreadPerGroup];
#if KANGAROO_METAL_USE_SYMMETRY
    symClassCache[g] = static_cast<uint>(kangaroos[idx0 + 11u * params.nbThreadPerGroup]) & 1u;
#endif
  }

  for(uint run = 0; run < kNbRun; run++) {

    for(uint g = 0; g < kGpuGroupSize; g++) {
      uint j = jump_index(pxCache[g][0]);
#if KANGAROO_METAL_USE_SYMMETRY
      j = jump_index_sym(pxCache[g][0], symClassCache[g]);
#endif
      mod_sub_256_tg(dxInv[g], pxCache[g], tgJumpX[j]);
    }

#if KANGAROO_METAL_ENABLE_INV_PROFILE
    mod_inv_grouped(
        dxInv,
        prefix,
        invCalls,
        invFallback,
        invIterSum,
        invIterMax,
        invFallbackIterLimit,
        invFallbackGcd,
        invFallbackNormNeg,
        invFallbackNormPos);
#else
    mod_inv_grouped(dxInv, prefix);
#endif

    for(uint g = 0; g < kGpuGroupSize; g++) {
      uint j = jump_index(pxCache[g][0]);
#if KANGAROO_METAL_USE_SYMMETRY
      j = jump_index_sym(pxCache[g][0], symClassCache[g]);
#endif

      ulong invUse[4];
      copy4(invUse, dxInv[g]);
      if(is_zero_256(invUse)) {
        uint jAlt = (j + 1u) & (kNbJump - 1u);
#if KANGAROO_METAL_USE_SYMMETRY
        jAlt = jump_next_sym(j, symClassCache[g]);
#endif
        ulong dxAlt[4];
        mod_sub_256_tg(dxAlt, pxCache[g], tgJumpX[jAlt]);
        if(is_zero_256(dxAlt)) {
          continue;
        }
        mod_inv_pow_k1(invUse, dxAlt);
        if(is_zero_256(invUse)) {
          continue;
        }
        j = jAlt;
      }

      ulong rx[4];
      ulong ry[4];
      point_add_affine_tg(rx, ry, pxCache[g], pyCache[g], tgJumpX[j], tgJumpY[j], invUse);

#if KANGAROO_METAL_USE_SYMMETRY
      // 有符号距离累加 + 对称翻转
      dist_add_signed_192(dCache[g], tgJumpD[j][0], tgJumpD[j][1]);
      if(mod_positive_256(ry)) {
        dist_toggle_sign_192(dCache[g]);
        symClassCache[g] ^= 1u;
      }
#else
      ulong carry = 0ull;
      dCache[g][0] = addcarry_u64(dCache[g][0], tgJumpD[j][0], carry);
      dCache[g][1] = addcarry_u64(dCache[g][1], tgJumpD[j][1], carry);
      dCache[g][2] = addcarry_u64(dCache[g][2], 0ull, carry);
#endif

      pxCache[g][0] = rx[0];
      pxCache[g][1] = rx[1];
      pxCache[g][2] = rx[2];
      pxCache[g][3] = rx[3];

      pyCache[g][0] = ry[0];
      pyCache[g][1] = ry[1];
      pyCache[g][2] = ry[2];
      pyCache[g][3] = ry[3];

      if((rx[3] & params.dpMask) == 0ull) {
        uint pos = atomic_fetch_add_explicit(counter, 1u, memory_order_relaxed);
        if(pos < params.maxFound) {
          uint outBase = pos * kItemSize32 + 1u;

          outWords[outBase + 0u] = lo32(rx[0]);
          outWords[outBase + 1u] = hi32(rx[0]);
          outWords[outBase + 2u] = lo32(rx[1]);
          outWords[outBase + 3u] = hi32(rx[1]);
          outWords[outBase + 4u] = lo32(rx[2]);
          outWords[outBase + 5u] = hi32(rx[2]);
          outWords[outBase + 6u] = lo32(rx[3]);
          outWords[outBase + 7u] = hi32(rx[3]);

          outWords[outBase + 8u]  = lo32(dCache[g][0]);
          outWords[outBase + 9u]  = hi32(dCache[g][0]);
          outWords[outBase + 10u] = lo32(dCache[g][1]);
          outWords[outBase + 11u] = hi32(dCache[g][1]);
          outWords[outBase + 12u] = lo32(dCache[g][2]);
          outWords[outBase + 13u] = hi32(dCache[g][2]);

          ulong kIdx = static_cast<ulong>(localTid) +
                       static_cast<ulong>(g) * static_cast<ulong>(params.nbThreadPerGroup) +
                       static_cast<ulong>(groupId) *
                           static_cast<ulong>(params.nbThreadPerGroup * kGpuGroupSize);

          outWords[outBase + 14u] = lo32(kIdx);
          outWords[outBase + 15u] = hi32(kIdx);
        }
      }
    }
  }

  // Write back once per launch after all local nbRun updates are done.
  for(uint g = 0; g < kGpuGroupSize; g++) {
    const uint idx0 = blockBase + g * strideSize + localTid;
    kangaroos[idx0 + 0u * params.nbThreadPerGroup] = pxCache[g][0];
    kangaroos[idx0 + 1u * params.nbThreadPerGroup] = pxCache[g][1];
    kangaroos[idx0 + 2u * params.nbThreadPerGroup] = pxCache[g][2];
    kangaroos[idx0 + 3u * params.nbThreadPerGroup] = pxCache[g][3];

    kangaroos[idx0 + 4u * params.nbThreadPerGroup] = pyCache[g][0];
    kangaroos[idx0 + 5u * params.nbThreadPerGroup] = pyCache[g][1];
    kangaroos[idx0 + 6u * params.nbThreadPerGroup] = pyCache[g][2];
    kangaroos[idx0 + 7u * params.nbThreadPerGroup] = pyCache[g][3];

    kangaroos[idx0 + 8u * params.nbThreadPerGroup]  = dCache[g][0];
    kangaroos[idx0 + 9u * params.nbThreadPerGroup]  = dCache[g][1];
    kangaroos[idx0 + 10u * params.nbThreadPerGroup] = dCache[g][2];
#if KANGAROO_METAL_USE_SYMMETRY
    kangaroos[idx0 + 11u * params.nbThreadPerGroup] = static_cast<ulong>(symClassCache[g]);
#endif
  }

#if KANGAROO_METAL_ENABLE_INV_PROFILE
  if(params.profileMode != 0u) {
    atomic_fetch_add_explicit(&(invProfile[0]), invCalls, memory_order_relaxed);
    atomic_fetch_add_explicit(&(invProfile[1]), invFallback, memory_order_relaxed);
    atomic_fetch_add_explicit(&(invProfile[2]), invIterSum, memory_order_relaxed);
    atomic_fetch_max_explicit(&(invProfile[3]), invIterMax, memory_order_relaxed);
    atomic_fetch_add_explicit(&(invProfile[4]), invFallbackIterLimit, memory_order_relaxed);
    atomic_fetch_add_explicit(&(invProfile[5]), invFallbackGcd, memory_order_relaxed);
    atomic_fetch_add_explicit(&(invProfile[6]), invFallbackNormNeg, memory_order_relaxed);
    atomic_fetch_add_explicit(&(invProfile[7]), invFallbackNormPos, memory_order_relaxed);
  }
#endif
}

// Variant: do not keep px/py/d in thread-local cache across nbRun.
// This reduces per-thread register/local-memory pressure, which can help at larger kGpuGroupSize,
// at the cost of more global memory traffic.
kernel void kangaroo_step_nocache(device ulong *kangaroos [[buffer(0)]],
                                  device uint *outWords [[buffer(1)]],
                                  constant ulong2 *jumpD [[buffer(2)]],
                                  constant ulong4 *jumpX [[buffer(3)]],
                                  constant ulong4 *jumpY [[buffer(4)]],
                                  constant KernelParams &params [[buffer(5)]],
                                  device atomic_uint *invProfile [[buffer(6)]],
                                  uint localTid [[thread_position_in_threadgroup]],
                                  uint groupId [[threadgroup_position_in_grid]]) {

  if(localTid >= params.nbThreadPerGroup || groupId >= params.nbThreadGroup) {
    return;
  }

  threadgroup ulong tgJumpD[kNbJump][2];
  threadgroup ulong tgJumpX[kNbJump][4];
  threadgroup ulong tgJumpY[kNbJump][4];

  if(localTid < kNbJump) {
    ulong2 d = jumpD[localTid];
    ulong4 x = jumpX[localTid];
    ulong4 y = jumpY[localTid];

    tgJumpD[localTid][0] = d.x;
    tgJumpD[localTid][1] = d.y;

    tgJumpX[localTid][0] = x.x;
    tgJumpX[localTid][1] = x.y;
    tgJumpX[localTid][2] = x.z;
    tgJumpX[localTid][3] = x.w;

    tgJumpY[localTid][0] = y.x;
    tgJumpY[localTid][1] = y.y;
    tgJumpY[localTid][2] = y.z;
    tgJumpY[localTid][3] = y.w;
  }

  threadgroup_barrier(mem_flags::mem_threadgroup);

  const uint nt = params.nbThreadPerGroup;
  const uint blockSize = nt * params.kSize * kGpuGroupSize;
  const uint strideSize = nt * params.kSize;
  const uint blockBase = groupId * blockSize;

  device atomic_uint *counter = reinterpret_cast<device atomic_uint *>(outWords);

  thread ulong prefix[kGpuGroupSize][4];
  thread uint dxZeroMask[kGpuGroupSize];
#if KANGAROO_METAL_USE_SYMMETRY
  thread uint symClassCache[kGpuGroupSize];
#endif
#if KANGAROO_METAL_ENABLE_INV_PROFILE
  uint invCalls = 0u;
  uint invFallback = 0u;
  uint invIterSum = 0u;
  uint invIterMax = 0u;
  uint invFallbackIterLimit = 0u;
  uint invFallbackGcd = 0u;
  uint invFallbackNormNeg = 0u;
  uint invFallbackNormPos = 0u;
#endif

#if KANGAROO_METAL_USE_SYMMETRY
  for(uint g = 0; g < kGpuGroupSize; g++) {
    const uint idx0 = blockBase + g * strideSize + localTid;
    symClassCache[g] = static_cast<uint>(kangaroos[idx0 + 11u * nt]) & 1u;
  }
#endif

  for(uint run = 0; run < kNbRun; run++) {

    for(uint g = 0; g < kGpuGroupSize; g++) {
      const uint idx0 = blockBase + g * strideSize + localTid;

      ulong px[4];
      px[0] = kangaroos[idx0 + 0u * nt];
      px[1] = kangaroos[idx0 + 1u * nt];
      px[2] = kangaroos[idx0 + 2u * nt];
      px[3] = kangaroos[idx0 + 3u * nt];

      uint j = jump_index(px[0]);
#if KANGAROO_METAL_USE_SYMMETRY
      j = jump_index_sym(px[0], symClassCache[g]);
#endif
      ulong dx[4];
      mod_sub_256_tg(dx, px, tgJumpX[j]);
      ulong factor[4];
      dxZeroMask[g] = inv_factor_masked(factor, dx);
      if(g == 0u) {
        copy4(prefix[0], factor);
      } else {
        ulong pref[4];
        mod_mul_k1(pref, prefix[g - 1u], factor);
        copy4(prefix[g], pref);
      }
    }

    ulong inv[4];
    copy4(inv, prefix[kGpuGroupSize - 1u]);
#if KANGAROO_METAL_ENABLE_INV_PROFILE
    uint invIter = 0u;
    uint invFallbackNow = 0u;
    uint invFallbackReason = 0u;
    mod_inv_k1(inv, inv, invIter, invFallbackNow, invFallbackReason);
    invCalls += 1u;
    invFallback += invFallbackNow;
    invIterSum += invIter;
    if(invIter > invIterMax) {
      invIterMax = invIter;
    }
    if(invFallbackNow != 0u) {
      if(invFallbackReason == 1u) {
        invFallbackIterLimit += 1u;
      } else if(invFallbackReason == 2u) {
        invFallbackGcd += 1u;
      } else if(invFallbackReason == 3u) {
        invFallbackNormNeg += 1u;
      } else if(invFallbackReason == 4u) {
        invFallbackNormPos += 1u;
      }
    }
#else
    mod_inv_pow_k1(inv, inv);
#endif

    for(int gi = static_cast<int>(kGpuGroupSize) - 1; gi >= 0; gi--) {
      const uint g = static_cast<uint>(gi);
      const uint idx0 = blockBase + g * strideSize + localTid;

      ulong px[4];
      px[0] = kangaroos[idx0 + 0u * nt];
      px[1] = kangaroos[idx0 + 1u * nt];
      px[2] = kangaroos[idx0 + 2u * nt];
      px[3] = kangaroos[idx0 + 3u * nt];

      ulong py[4];
      py[0] = kangaroos[idx0 + 4u * nt];
      py[1] = kangaroos[idx0 + 5u * nt];
      py[2] = kangaroos[idx0 + 6u * nt];
      py[3] = kangaroos[idx0 + 7u * nt];

      ulong d0 = kangaroos[idx0 + 8u * nt];
      ulong d1 = kangaroos[idx0 + 9u * nt];
      ulong d2 = kangaroos[idx0 + 10u * nt];

      uint j = jump_index(px[0]);
#if KANGAROO_METAL_USE_SYMMETRY
      j = jump_index_sym(px[0], symClassCache[g]);
#endif
      ulong dx[4];
      mod_sub_256_tg(dx, px, tgJumpX[j]);
      ulong dxInv[4];
      if(g == 0u) {
        copy4(dxInv, inv);
      } else {
        mod_mul_k1(dxInv, prefix[g - 1u], inv);
      }
      if(dxZeroMask[g] != 0u) {
        set_zero_256(dxInv);
      }

      ulong invUse[4];
      copy4(invUse, dxInv);
      if(is_zero_256(invUse)) {
        uint jAlt = (j + 1u) & (kNbJump - 1u);
#if KANGAROO_METAL_USE_SYMMETRY
        jAlt = jump_next_sym(j, symClassCache[g]);
#endif
        ulong dxAlt[4];
        mod_sub_256_tg(dxAlt, px, tgJumpX[jAlt]);
        if(is_zero_256(dxAlt)) {
          ulong factorSkip[4];
          if(dxZeroMask[g] != 0u) {
            set_one_256(factorSkip);
          } else {
            copy4(factorSkip, dx);
          }
          if(g != 0u) {
            mod_mul_k1(inv, inv, factorSkip);
          }
          continue;
        }
        mod_inv_pow_k1(invUse, dxAlt);
        if(is_zero_256(invUse)) {
          ulong factorSkip[4];
          if(dxZeroMask[g] != 0u) {
            set_one_256(factorSkip);
          } else {
            copy4(factorSkip, dx);
          }
          if(g != 0u) {
            mod_mul_k1(inv, inv, factorSkip);
          }
          continue;
        }
        j = jAlt;
      }

      ulong rx[4];
      ulong ry[4];
      point_add_affine_tg(rx, ry, px, py, tgJumpX[j], tgJumpY[j], invUse);

#if KANGAROO_METAL_USE_SYMMETRY
      // 有符号距离累加 + 对称翻转
      dist_add_signed_192(d0, d1, d2, tgJumpD[j][0], tgJumpD[j][1]);
      if(mod_positive_256(ry)) {
        dist_toggle_sign_192(d0, d1, d2);
        symClassCache[g] ^= 1u;
      }
#else
      ulong carry = 0ull;
      d0 = addcarry_u64(d0, tgJumpD[j][0], carry);
      d1 = addcarry_u64(d1, tgJumpD[j][1], carry);
      d2 = addcarry_u64(d2, 0ull, carry);
#endif

      if(g != 0u) {
        ulong factor[4];
        if(dxZeroMask[g] != 0u) {
          set_one_256(factor);
        } else {
          copy4(factor, dx);
        }
        mod_mul_k1(inv, inv, factor);
      }

      // Store state immediately so subsequent runs see updated values.
      kangaroos[idx0 + 0u * nt] = rx[0];
      kangaroos[idx0 + 1u * nt] = rx[1];
      kangaroos[idx0 + 2u * nt] = rx[2];
      kangaroos[idx0 + 3u * nt] = rx[3];

      kangaroos[idx0 + 4u * nt] = ry[0];
      kangaroos[idx0 + 5u * nt] = ry[1];
      kangaroos[idx0 + 6u * nt] = ry[2];
      kangaroos[idx0 + 7u * nt] = ry[3];

      kangaroos[idx0 + 8u * nt]  = d0;
      kangaroos[idx0 + 9u * nt]  = d1;
      kangaroos[idx0 + 10u * nt] = d2;
#if KANGAROO_METAL_USE_SYMMETRY
      kangaroos[idx0 + 11u * nt] = static_cast<ulong>(symClassCache[g]);
#endif

      if((rx[3] & params.dpMask) == 0ull) {
        uint pos = atomic_fetch_add_explicit(counter, 1u, memory_order_relaxed);
        if(pos < params.maxFound) {
          uint outBase = pos * kItemSize32 + 1u;

          outWords[outBase + 0u] = lo32(rx[0]);
          outWords[outBase + 1u] = hi32(rx[0]);
          outWords[outBase + 2u] = lo32(rx[1]);
          outWords[outBase + 3u] = hi32(rx[1]);
          outWords[outBase + 4u] = lo32(rx[2]);
          outWords[outBase + 5u] = hi32(rx[2]);
          outWords[outBase + 6u] = lo32(rx[3]);
          outWords[outBase + 7u] = hi32(rx[3]);

          outWords[outBase + 8u]  = lo32(d0);
          outWords[outBase + 9u]  = hi32(d0);
          outWords[outBase + 10u] = lo32(d1);
          outWords[outBase + 11u] = hi32(d1);
          outWords[outBase + 12u] = lo32(d2);
          outWords[outBase + 13u] = hi32(d2);

          ulong kIdx = static_cast<ulong>(localTid) +
                       static_cast<ulong>(g) * static_cast<ulong>(nt) +
                       static_cast<ulong>(groupId) * static_cast<ulong>(nt * kGpuGroupSize);

          outWords[outBase + 14u] = lo32(kIdx);
          outWords[outBase + 15u] = hi32(kIdx);
        }
      }
    }
  }

#if KANGAROO_METAL_ENABLE_INV_PROFILE
  if(params.profileMode != 0u) {
    atomic_fetch_add_explicit(&(invProfile[0]), invCalls, memory_order_relaxed);
    atomic_fetch_add_explicit(&(invProfile[1]), invFallback, memory_order_relaxed);
    atomic_fetch_add_explicit(&(invProfile[2]), invIterSum, memory_order_relaxed);
    atomic_fetch_max_explicit(&(invProfile[3]), invIterMax, memory_order_relaxed);
    atomic_fetch_add_explicit(&(invProfile[4]), invFallbackIterLimit, memory_order_relaxed);
    atomic_fetch_add_explicit(&(invProfile[5]), invFallbackGcd, memory_order_relaxed);
    atomic_fetch_add_explicit(&(invProfile[6]), invFallbackNormNeg, memory_order_relaxed);
    atomic_fetch_add_explicit(&(invProfile[7]), invFallbackNormPos, memory_order_relaxed);
  }
#endif
}

// Jacobian + affine jump prototype:
// keep kangaroo state in Jacobian during the launch, normalize once per run (for jump/DP),
// and write back affine state at the end so host-side data layout stays unchanged.
kernel void kangaroo_step_jacobian_mixed(device ulong *kangaroos [[buffer(0)]],
                                         device uint *outWords [[buffer(1)]],
                                         constant ulong2 *jumpD [[buffer(2)]],
                                         constant ulong4 *jumpX [[buffer(3)]],
                                         constant ulong4 *jumpY [[buffer(4)]],
                                         constant KernelParams &params [[buffer(5)]],
                                         device atomic_uint *invProfile [[buffer(6)]],
                                         uint localTid [[thread_position_in_threadgroup]],
                                         uint groupId [[threadgroup_position_in_grid]],
                                         uint simdLane [[thread_index_in_simdgroup]]) {

  if(localTid >= params.nbThreadPerGroup || groupId >= params.nbThreadGroup) {
    return;
  }

  threadgroup ulong tgJumpD[kNbJump][2];
  threadgroup ulong tgJumpX[kNbJump][4];
  threadgroup ulong tgJumpY[kNbJump][4];

  if(localTid < kNbJump) {
    ulong2 d = jumpD[localTid];
    ulong4 x = jumpX[localTid];
    ulong4 y = jumpY[localTid];

    tgJumpD[localTid][0] = d.x;
    tgJumpD[localTid][1] = d.y;

    tgJumpX[localTid][0] = x.x;
    tgJumpX[localTid][1] = x.y;
    tgJumpX[localTid][2] = x.z;
    tgJumpX[localTid][3] = x.w;

    tgJumpY[localTid][0] = y.x;
    tgJumpY[localTid][1] = y.y;
    tgJumpY[localTid][2] = y.z;
    tgJumpY[localTid][3] = y.w;
  }

  threadgroup_barrier(mem_flags::mem_threadgroup);

  const uint nt = params.nbThreadPerGroup;
  const uint blockSize = nt * params.kSize * kGpuGroupSize;
  const uint strideSize = nt * params.kSize;
  const uint blockBase = groupId * blockSize;
  const bool simdInvEligible = ((params.nbThreadPerGroup & (kSimdWidth - 1u)) == 0u) &&
                               (params.nbThreadPerGroup <= (kMaxCoopSimdGroups * kSimdWidth));

  device atomic_uint *counter = reinterpret_cast<device atomic_uint *>(outWords);

  thread ulong jacX[kGpuGroupSize][4];
  thread ulong jacY[kGpuGroupSize][4];
  thread ulong jacZ[kGpuGroupSize][4];
  thread ulong dCache[kGpuGroupSize][3];
  thread ulong zInv[kGpuGroupSize][4];
  thread ulong prefix[kGpuGroupSize][4];
#if KANGAROO_METAL_ENABLE_INV_PROFILE
  uint invCalls = 0u;
  uint invFallback = 0u;
  uint invIterSum = 0u;
  uint invIterMax = 0u;
  uint invFallbackIterLimit = 0u;
  uint invFallbackGcd = 0u;
  uint invFallbackNormNeg = 0u;
  uint invFallbackNormPos = 0u;
#endif

  // Input state is affine (x,y). Start Jacobian with Z=1.
  for(uint g = 0; g < kGpuGroupSize; g++) {
    const uint idx0 = blockBase + g * strideSize + localTid;
    jacX[g][0] = kangaroos[idx0 + 0u * nt];
    jacX[g][1] = kangaroos[idx0 + 1u * nt];
    jacX[g][2] = kangaroos[idx0 + 2u * nt];
    jacX[g][3] = kangaroos[idx0 + 3u * nt];

    jacY[g][0] = kangaroos[idx0 + 4u * nt];
    jacY[g][1] = kangaroos[idx0 + 5u * nt];
    jacY[g][2] = kangaroos[idx0 + 6u * nt];
    jacY[g][3] = kangaroos[idx0 + 7u * nt];

    set_one_256(jacZ[g]);

    dCache[g][0] = kangaroos[idx0 + 8u * nt];
    dCache[g][1] = kangaroos[idx0 + 9u * nt];
    dCache[g][2] = kangaroos[idx0 + 10u * nt];
  }

  for(uint run = 0; run < kNbRun; run++) {
    // Batch invert Z for all local kangaroos once this run.
    for(uint g = 0; g < kGpuGroupSize; g++) {
      copy4(zInv[g], jacZ[g]);
    }

#if KANGAROO_METAL_ENABLE_INV_PROFILE
    if(simdInvEligible) {
      mod_inv_grouped_simd(
          zInv,
          prefix,
          simdLane,
          invCalls,
          invFallback,
          invIterSum,
          invIterMax,
          invFallbackIterLimit,
          invFallbackGcd,
          invFallbackNormNeg,
          invFallbackNormPos);
    } else {
      mod_inv_grouped(
          zInv,
          prefix,
          invCalls,
          invFallback,
          invIterSum,
          invIterMax,
          invFallbackIterLimit,
          invFallbackGcd,
          invFallbackNormNeg,
          invFallbackNormPos);
    }
#else
    if(simdInvEligible) {
      mod_inv_grouped_simd(zInv, prefix, simdLane);
    } else {
      mod_inv_grouped(zInv, prefix);
    }
#endif

    for(uint g = 0; g < kGpuGroupSize; g++) {
      // Normalize current Jacobian point to affine for jump/DP logic.
      ulong z2Inv[4];
      mod_sqr_k1(z2Inv, zInv[g]);

      ulong xAff[4];
      mod_mul_k1(xAff, jacX[g], z2Inv);

      // Prototype note: DP check is on current affine point (before this run's jump).
      if((xAff[3] & params.dpMask) == 0ull) {
        uint pos = atomic_fetch_add_explicit(counter, 1u, memory_order_relaxed);
        if(pos < params.maxFound) {
          uint outBase = pos * kItemSize32 + 1u;

          outWords[outBase + 0u] = lo32(xAff[0]);
          outWords[outBase + 1u] = hi32(xAff[0]);
          outWords[outBase + 2u] = lo32(xAff[1]);
          outWords[outBase + 3u] = hi32(xAff[1]);
          outWords[outBase + 4u] = lo32(xAff[2]);
          outWords[outBase + 5u] = hi32(xAff[2]);
          outWords[outBase + 6u] = lo32(xAff[3]);
          outWords[outBase + 7u] = hi32(xAff[3]);

          outWords[outBase + 8u]  = lo32(dCache[g][0]);
          outWords[outBase + 9u]  = hi32(dCache[g][0]);
          outWords[outBase + 10u] = lo32(dCache[g][1]);
          outWords[outBase + 11u] = hi32(dCache[g][1]);
          outWords[outBase + 12u] = lo32(dCache[g][2]);
          outWords[outBase + 13u] = hi32(dCache[g][2]);

          ulong kIdx = static_cast<ulong>(localTid) +
                       static_cast<ulong>(g) * static_cast<ulong>(nt) +
                       static_cast<ulong>(groupId) * static_cast<ulong>(nt * kGpuGroupSize);

          outWords[outBase + 14u] = lo32(kIdx);
          outWords[outBase + 15u] = hi32(kIdx);
        }
      }

      const uint j = static_cast<uint>(xAff[0]) & (kNbJump - 1u);

      ulong nx[4];
      ulong ny[4];
      ulong nz[4];
      point_add_mixed_jacobian_tg(nx, ny, nz, jacX[g], jacY[g], jacZ[g], tgJumpX[j], tgJumpY[j]);
      copy4(jacX[g], nx);
      copy4(jacY[g], ny);
      copy4(jacZ[g], nz);

      ulong carry = 0ull;
      dCache[g][0] = addcarry_u64(dCache[g][0], tgJumpD[j][0], carry);
      dCache[g][1] = addcarry_u64(dCache[g][1], tgJumpD[j][1], carry);
      dCache[g][2] = addcarry_u64(dCache[g][2], 0ull, carry);
    }
  }

  // Persist state back in affine so host/CPU paths remain unchanged.
  for(uint g = 0; g < kGpuGroupSize; g++) {
    copy4(zInv[g], jacZ[g]);
  }

#if KANGAROO_METAL_ENABLE_INV_PROFILE
  if(simdInvEligible) {
    mod_inv_grouped_simd(
        zInv,
        prefix,
        simdLane,
        invCalls,
        invFallback,
        invIterSum,
        invIterMax,
        invFallbackIterLimit,
        invFallbackGcd,
        invFallbackNormNeg,
        invFallbackNormPos);
  } else {
    mod_inv_grouped(
        zInv,
        prefix,
        invCalls,
        invFallback,
        invIterSum,
        invIterMax,
        invFallbackIterLimit,
        invFallbackGcd,
        invFallbackNormNeg,
        invFallbackNormPos);
  }
#else
  if(simdInvEligible) {
    mod_inv_grouped_simd(zInv, prefix, simdLane);
  } else {
    mod_inv_grouped(zInv, prefix);
  }
#endif

  for(uint g = 0; g < kGpuGroupSize; g++) {
    const uint idx0 = blockBase + g * strideSize + localTid;

    ulong z2Inv[4];
    mod_sqr_k1(z2Inv, zInv[g]);

    ulong xAff[4];
    mod_mul_k1(xAff, jacX[g], z2Inv);

    ulong z3Inv[4];
    mod_mul_k1(z3Inv, z2Inv, zInv[g]);
    ulong yAff[4];
    mod_mul_k1(yAff, jacY[g], z3Inv);

    kangaroos[idx0 + 0u * nt] = xAff[0];
    kangaroos[idx0 + 1u * nt] = xAff[1];
    kangaroos[idx0 + 2u * nt] = xAff[2];
    kangaroos[idx0 + 3u * nt] = xAff[3];

    kangaroos[idx0 + 4u * nt] = yAff[0];
    kangaroos[idx0 + 5u * nt] = yAff[1];
    kangaroos[idx0 + 6u * nt] = yAff[2];
    kangaroos[idx0 + 7u * nt] = yAff[3];

    kangaroos[idx0 + 8u * nt]  = dCache[g][0];
    kangaroos[idx0 + 9u * nt]  = dCache[g][1];
    kangaroos[idx0 + 10u * nt] = dCache[g][2];
  }

#if KANGAROO_METAL_ENABLE_INV_PROFILE
  if(params.profileMode != 0u) {
    atomic_fetch_add_explicit(&(invProfile[0]), invCalls, memory_order_relaxed);
    atomic_fetch_add_explicit(&(invProfile[1]), invFallback, memory_order_relaxed);
    atomic_fetch_add_explicit(&(invProfile[2]), invIterSum, memory_order_relaxed);
    atomic_fetch_max_explicit(&(invProfile[3]), invIterMax, memory_order_relaxed);
    atomic_fetch_add_explicit(&(invProfile[4]), invFallbackIterLimit, memory_order_relaxed);
    atomic_fetch_add_explicit(&(invProfile[5]), invFallbackGcd, memory_order_relaxed);
    atomic_fetch_add_explicit(&(invProfile[6]), invFallbackNormNeg, memory_order_relaxed);
    atomic_fetch_add_explicit(&(invProfile[7]), invFallbackNormPos, memory_order_relaxed);
  }
#endif
}

// SIMD cooperative inversion over per-thread product:
// each thread still processes kGpuGroupSize kangaroos, but 32 lanes cooperate
// to invert 32 thread-products with one field inversion per simdgroup.
kernel void kangaroo_step_simd_inv(device ulong *kangaroos [[buffer(0)]],
                                   device uint *outWords [[buffer(1)]],
                                   constant ulong2 *jumpD [[buffer(2)]],
                                   constant ulong4 *jumpX [[buffer(3)]],
                                   constant ulong4 *jumpY [[buffer(4)]],
                                   constant KernelParams &params [[buffer(5)]],
                                   device atomic_uint *invProfile [[buffer(6)]],
                                   uint localTid [[thread_position_in_threadgroup]],
                                   uint groupId [[threadgroup_position_in_grid]],
                                   uint simdLane [[thread_index_in_simdgroup]]) {

  if(localTid >= params.nbThreadPerGroup || groupId >= params.nbThreadGroup) {
    return;
  }
  if((params.nbThreadPerGroup & (kSimdWidth - 1u)) != 0u ||
     params.nbThreadPerGroup > (kMaxCoopSimdGroups * kSimdWidth)) {
    return;
  }

  threadgroup ulong tgJumpD[kNbJump][2];
  threadgroup ulong tgJumpX[kNbJump][4];
  threadgroup ulong tgJumpY[kNbJump][4];

  if(localTid < kNbJump) {
    ulong2 d = jumpD[localTid];
    ulong4 x = jumpX[localTid];
    ulong4 y = jumpY[localTid];

    tgJumpD[localTid][0] = d.x;
    tgJumpD[localTid][1] = d.y;

    tgJumpX[localTid][0] = x.x;
    tgJumpX[localTid][1] = x.y;
    tgJumpX[localTid][2] = x.z;
    tgJumpX[localTid][3] = x.w;

    tgJumpY[localTid][0] = y.x;
    tgJumpY[localTid][1] = y.y;
    tgJumpY[localTid][2] = y.z;
    tgJumpY[localTid][3] = y.w;
  }

  threadgroup_barrier(mem_flags::mem_threadgroup);

  const uint nt = params.nbThreadPerGroup;
  const uint blockSize = nt * params.kSize * kGpuGroupSize;
  const uint strideSize = nt * params.kSize;
  const uint blockBase = groupId * blockSize;

  device atomic_uint *counter = reinterpret_cast<device atomic_uint *>(outWords);

  thread ulong prefix[kGpuGroupSize][4];
  thread uint dxZeroMask[kGpuGroupSize];
#if KANGAROO_METAL_USE_SYMMETRY
  thread uint symClassCache[kGpuGroupSize];
#endif
#if KANGAROO_METAL_ENABLE_INV_PROFILE
  uint invCalls = 0u;
  uint invFallback = 0u;
  uint invIterSum = 0u;
  uint invIterMax = 0u;
  uint invFallbackIterLimit = 0u;
  uint invFallbackGcd = 0u;
  uint invFallbackNormNeg = 0u;
  uint invFallbackNormPos = 0u;
#endif

#if KANGAROO_METAL_USE_SYMMETRY
  for(uint g = 0; g < kGpuGroupSize; g++) {
    const uint idx0 = blockBase + g * strideSize + localTid;
    symClassCache[g] = static_cast<uint>(kangaroos[idx0 + 11u * nt]) & 1u;
  }
#endif

  for(uint run = 0; run < kNbRun; run++) {
    for(uint g = 0; g < kGpuGroupSize; g++) {
      const uint idx0 = blockBase + g * strideSize + localTid;

      ulong px[4];
      px[0] = kangaroos[idx0 + 0u * nt];
      px[1] = kangaroos[idx0 + 1u * nt];
      px[2] = kangaroos[idx0 + 2u * nt];
      px[3] = kangaroos[idx0 + 3u * nt];

      uint j = jump_index(px[0]);
#if KANGAROO_METAL_USE_SYMMETRY
      j = jump_index_sym(px[0], symClassCache[g]);
#endif
      ulong dx[4];
      mod_sub_256_tg(dx, px, tgJumpX[j]);
      ulong factor[4];
      dxZeroMask[g] = inv_factor_masked(factor, dx);

      if(g == 0u) {
        copy4(prefix[0], factor);
      } else {
        mod_mul_k1(prefix[g], prefix[g - 1u], factor);
      }
    }

    // Cooperative inversion across lanes in registers (no threadgroup scratch).
    // Compute inverse of each lane's product using prefix/suffix scans + one inverse.
    ulong laneProd[4];
    copy4(laneProd, prefix[kGpuGroupSize - 1u]);

    ulong prefIncl[4];
    copy4(prefIncl, laneProd);
    for(uint offset = 1u; offset < kSimdWidth; offset <<= 1u) {
      ulong up[4];
      simd_shuffle_up_256(up, prefIncl, offset);
      if(simdLane >= offset) {
        mod_mul_k1(prefIncl, prefIncl, up);
      }
    }

    ulong suffIncl[4];
    copy4(suffIncl, laneProd);
    for(uint offset = 1u; offset < kSimdWidth; offset <<= 1u) {
      ulong down[4];
      simd_shuffle_down_256(down, suffIncl, offset);
      if((simdLane + offset) < kSimdWidth) {
        mod_mul_k1(suffIncl, suffIncl, down);
      }
    }

    ulong invAll[4];
    simd_broadcast_256(invAll, prefIncl, kSimdWidth - 1u);
#if KANGAROO_METAL_ENABLE_INV_PROFILE
    if(simdLane == (kSimdWidth - 1u)) {
      uint invIter = 0u;
      uint invFallbackNow = 0u;
      uint invFallbackReason = 0u;
      mod_inv_k1(invAll, invAll, invIter, invFallbackNow, invFallbackReason);
      invCalls += 1u;
      invFallback += invFallbackNow;
      invIterSum += invIter;
      if(invIter > invIterMax) {
        invIterMax = invIter;
      }
      if(invFallbackNow != 0u) {
        if(invFallbackReason == 1u) {
          invFallbackIterLimit += 1u;
        } else if(invFallbackReason == 2u) {
          invFallbackGcd += 1u;
        } else if(invFallbackReason == 3u) {
          invFallbackNormNeg += 1u;
        } else if(invFallbackReason == 4u) {
          invFallbackNormPos += 1u;
        }
      }
    }
#else
    if(simdLane == (kSimdWidth - 1u)) {
      mod_inv_pow_k1(invAll, invAll);
    }
#endif
    simd_broadcast_256(invAll, invAll, kSimdWidth - 1u);

    ulong prefExcl[4];
    if(simdLane == 0u) {
      set_one_256(prefExcl);
    } else {
      simd_shuffle_up_256(prefExcl, prefIncl, 1u);
    }

    ulong suffExcl[4];
    if(simdLane == (kSimdWidth - 1u)) {
      set_one_256(suffExcl);
    } else {
      simd_shuffle_down_256(suffExcl, suffIncl, 1u);
    }

    ulong inv[4];
    mod_mul_k1(inv, prefExcl, suffExcl);
    mod_mul_k1(inv, inv, invAll);

    for(int gi = static_cast<int>(kGpuGroupSize) - 1; gi >= 0; gi--) {
      const uint g = static_cast<uint>(gi);
      const uint idx0 = blockBase + g * strideSize + localTid;

      ulong px[4];
      px[0] = kangaroos[idx0 + 0u * nt];
      px[1] = kangaroos[idx0 + 1u * nt];
      px[2] = kangaroos[idx0 + 2u * nt];
      px[3] = kangaroos[idx0 + 3u * nt];

      ulong py[4];
      py[0] = kangaroos[idx0 + 4u * nt];
      py[1] = kangaroos[idx0 + 5u * nt];
      py[2] = kangaroos[idx0 + 6u * nt];
      py[3] = kangaroos[idx0 + 7u * nt];

      ulong d0 = kangaroos[idx0 + 8u * nt];
      ulong d1 = kangaroos[idx0 + 9u * nt];
      ulong d2 = kangaroos[idx0 + 10u * nt];

      uint j = jump_index(px[0]);
#if KANGAROO_METAL_USE_SYMMETRY
      j = jump_index_sym(px[0], symClassCache[g]);
#endif
      ulong dx[4];
      mod_sub_256_tg(dx, px, tgJumpX[j]);

      ulong dxInv[4];
      if(g == 0u) {
        copy4(dxInv, inv);
      } else {
        mod_mul_k1(dxInv, prefix[g - 1u], inv);
      }
      if(dxZeroMask[g] != 0u) {
        set_zero_256(dxInv);
      }

      ulong invUse[4];
      copy4(invUse, dxInv);
      if(is_zero_256(invUse)) {
        uint jAlt = (j + 1u) & (kNbJump - 1u);
#if KANGAROO_METAL_USE_SYMMETRY
        jAlt = jump_next_sym(j, symClassCache[g]);
#endif
        ulong dxAlt[4];
        mod_sub_256_tg(dxAlt, px, tgJumpX[jAlt]);
        if(is_zero_256(dxAlt)) {
          ulong factorSkip[4];
          if(dxZeroMask[g] != 0u) {
            set_one_256(factorSkip);
          } else {
            copy4(factorSkip, dx);
          }
          if(g != 0u) {
            mod_mul_k1(inv, inv, factorSkip);
          }
          continue;
        }
        mod_inv_pow_k1(invUse, dxAlt);
        if(is_zero_256(invUse)) {
          ulong factorSkip[4];
          if(dxZeroMask[g] != 0u) {
            set_one_256(factorSkip);
          } else {
            copy4(factorSkip, dx);
          }
          if(g != 0u) {
            mod_mul_k1(inv, inv, factorSkip);
          }
          continue;
        }
        j = jAlt;
      }

      ulong rx[4];
      ulong ry[4];
      point_add_affine_tg(rx, ry, px, py, tgJumpX[j], tgJumpY[j], invUse);

#if KANGAROO_METAL_USE_SYMMETRY
      // 有符号距离累加 + 对称翻转
      dist_add_signed_192(d0, d1, d2, tgJumpD[j][0], tgJumpD[j][1]);
      if(mod_positive_256(ry)) {
        dist_toggle_sign_192(d0, d1, d2);
        symClassCache[g] ^= 1u;
      }
#else
      ulong carry = 0ull;
      d0 = addcarry_u64(d0, tgJumpD[j][0], carry);
      d1 = addcarry_u64(d1, tgJumpD[j][1], carry);
      d2 = addcarry_u64(d2, 0ull, carry);
#endif

      if(g != 0u) {
        ulong factor[4];
        if(dxZeroMask[g] != 0u) {
          set_one_256(factor);
        } else {
          copy4(factor, dx);
        }
        mod_mul_k1(inv, inv, factor);
      }

      kangaroos[idx0 + 0u * nt] = rx[0];
      kangaroos[idx0 + 1u * nt] = rx[1];
      kangaroos[idx0 + 2u * nt] = rx[2];
      kangaroos[idx0 + 3u * nt] = rx[3];

      kangaroos[idx0 + 4u * nt] = ry[0];
      kangaroos[idx0 + 5u * nt] = ry[1];
      kangaroos[idx0 + 6u * nt] = ry[2];
      kangaroos[idx0 + 7u * nt] = ry[3];

      kangaroos[idx0 + 8u * nt]  = d0;
      kangaroos[idx0 + 9u * nt]  = d1;
      kangaroos[idx0 + 10u * nt] = d2;
#if KANGAROO_METAL_USE_SYMMETRY
      kangaroos[idx0 + 11u * nt] = static_cast<ulong>(symClassCache[g]);
#endif

      if((rx[3] & params.dpMask) == 0ull) {
        uint pos = atomic_fetch_add_explicit(counter, 1u, memory_order_relaxed);
        if(pos < params.maxFound) {
          uint outBase = pos * kItemSize32 + 1u;

          outWords[outBase + 0u] = lo32(rx[0]);
          outWords[outBase + 1u] = hi32(rx[0]);
          outWords[outBase + 2u] = lo32(rx[1]);
          outWords[outBase + 3u] = hi32(rx[1]);
          outWords[outBase + 4u] = lo32(rx[2]);
          outWords[outBase + 5u] = hi32(rx[2]);
          outWords[outBase + 6u] = lo32(rx[3]);
          outWords[outBase + 7u] = hi32(rx[3]);

          outWords[outBase + 8u]  = lo32(d0);
          outWords[outBase + 9u]  = hi32(d0);
          outWords[outBase + 10u] = lo32(d1);
          outWords[outBase + 11u] = hi32(d1);
          outWords[outBase + 12u] = lo32(d2);
          outWords[outBase + 13u] = hi32(d2);

          ulong kIdx = static_cast<ulong>(localTid) +
                       static_cast<ulong>(g) * static_cast<ulong>(nt) +
                       static_cast<ulong>(groupId) * static_cast<ulong>(nt * kGpuGroupSize);

          outWords[outBase + 14u] = lo32(kIdx);
          outWords[outBase + 15u] = hi32(kIdx);
        }
      }
    }
  }

#if KANGAROO_METAL_ENABLE_INV_PROFILE
  if(params.profileMode != 0u) {
    atomic_fetch_add_explicit(&(invProfile[0]), invCalls, memory_order_relaxed);
    atomic_fetch_add_explicit(&(invProfile[1]), invFallback, memory_order_relaxed);
    atomic_fetch_add_explicit(&(invProfile[2]), invIterSum, memory_order_relaxed);
    atomic_fetch_max_explicit(&(invProfile[3]), invIterMax, memory_order_relaxed);
    atomic_fetch_add_explicit(&(invProfile[4]), invFallbackIterLimit, memory_order_relaxed);
    atomic_fetch_add_explicit(&(invProfile[5]), invFallbackGcd, memory_order_relaxed);
    atomic_fetch_add_explicit(&(invProfile[6]), invFallbackNormNeg, memory_order_relaxed);
    atomic_fetch_add_explicit(&(invProfile[7]), invFallbackNormPos, memory_order_relaxed);
  }
#endif
}

// Variant: keep only distance in thread-local cache across nbRun.
// This cuts repeated global d load/store traffic while keeping px/py uncached
// to avoid the larger register/local-memory pressure of full cache.
kernel void kangaroo_step_nocache_dcache(device ulong *kangaroos [[buffer(0)]],
                                         device uint *outWords [[buffer(1)]],
                                         constant ulong2 *jumpD [[buffer(2)]],
                                         constant ulong4 *jumpX [[buffer(3)]],
                                         constant ulong4 *jumpY [[buffer(4)]],
                                         constant KernelParams &params [[buffer(5)]],
                                         device atomic_uint *invProfile [[buffer(6)]],
                                         uint localTid [[thread_position_in_threadgroup]],
                                         uint groupId [[threadgroup_position_in_grid]]) {

  if(localTid >= params.nbThreadPerGroup || groupId >= params.nbThreadGroup) {
    return;
  }

  threadgroup ulong tgJumpD[kNbJump][2];
  threadgroup ulong tgJumpX[kNbJump][4];
  threadgroup ulong tgJumpY[kNbJump][4];

  if(localTid < kNbJump) {
    ulong2 d = jumpD[localTid];
    ulong4 x = jumpX[localTid];
    ulong4 y = jumpY[localTid];

    tgJumpD[localTid][0] = d.x;
    tgJumpD[localTid][1] = d.y;

    tgJumpX[localTid][0] = x.x;
    tgJumpX[localTid][1] = x.y;
    tgJumpX[localTid][2] = x.z;
    tgJumpX[localTid][3] = x.w;

    tgJumpY[localTid][0] = y.x;
    tgJumpY[localTid][1] = y.y;
    tgJumpY[localTid][2] = y.z;
    tgJumpY[localTid][3] = y.w;
  }

  threadgroup_barrier(mem_flags::mem_threadgroup);

  const uint nt = params.nbThreadPerGroup;
  const uint blockSize = nt * params.kSize * kGpuGroupSize;
  const uint strideSize = nt * params.kSize;
  const uint blockBase = groupId * blockSize;

  device atomic_uint *counter = reinterpret_cast<device atomic_uint *>(outWords);

  thread ulong dCache[kGpuGroupSize][3];
  thread ulong dxInv[kGpuGroupSize][4];
  thread ulong prefix[kGpuGroupSize][4];
#if KANGAROO_METAL_USE_SYMMETRY
  thread uint symClassCache[kGpuGroupSize];
#endif
#if KANGAROO_METAL_ENABLE_INV_PROFILE
  uint invCalls = 0u;
  uint invFallback = 0u;
  uint invIterSum = 0u;
  uint invIterMax = 0u;
  uint invFallbackIterLimit = 0u;
  uint invFallbackGcd = 0u;
  uint invFallbackNormNeg = 0u;
  uint invFallbackNormPos = 0u;
#endif

  // Keep d in local cache for the full launch.
  for(uint g = 0; g < kGpuGroupSize; g++) {
    const uint idx0 = blockBase + g * strideSize + localTid;
    dCache[g][0] = kangaroos[idx0 + 8u * nt];
    dCache[g][1] = kangaroos[idx0 + 9u * nt];
    dCache[g][2] = kangaroos[idx0 + 10u * nt];
#if KANGAROO_METAL_USE_SYMMETRY
    symClassCache[g] = static_cast<uint>(kangaroos[idx0 + 11u * nt]) & 1u;
#endif
  }

  for(uint run = 0; run < kNbRun; run++) {

    for(uint g = 0; g < kGpuGroupSize; g++) {
      const uint idx0 = blockBase + g * strideSize + localTid;

      ulong px[4];
      px[0] = kangaroos[idx0 + 0u * nt];
      px[1] = kangaroos[idx0 + 1u * nt];
      px[2] = kangaroos[idx0 + 2u * nt];
      px[3] = kangaroos[idx0 + 3u * nt];

      uint j = jump_index(px[0]);
#if KANGAROO_METAL_USE_SYMMETRY
      j = jump_index_sym(px[0], symClassCache[g]);
#endif
      mod_sub_256_tg(dxInv[g], px, tgJumpX[j]);
    }

#if KANGAROO_METAL_ENABLE_INV_PROFILE
    mod_inv_grouped(
        dxInv,
        prefix,
        invCalls,
        invFallback,
        invIterSum,
        invIterMax,
        invFallbackIterLimit,
        invFallbackGcd,
        invFallbackNormNeg,
        invFallbackNormPos);
#else
    mod_inv_grouped(dxInv, prefix);
#endif

    for(uint g = 0; g < kGpuGroupSize; g++) {
      const uint idx0 = blockBase + g * strideSize + localTid;

      ulong px[4];
      px[0] = kangaroos[idx0 + 0u * nt];
      px[1] = kangaroos[idx0 + 1u * nt];
      px[2] = kangaroos[idx0 + 2u * nt];
      px[3] = kangaroos[idx0 + 3u * nt];

      ulong py[4];
      py[0] = kangaroos[idx0 + 4u * nt];
      py[1] = kangaroos[idx0 + 5u * nt];
      py[2] = kangaroos[idx0 + 6u * nt];
      py[3] = kangaroos[idx0 + 7u * nt];

      uint j = jump_index(px[0]);
#if KANGAROO_METAL_USE_SYMMETRY
      j = jump_index_sym(px[0], symClassCache[g]);
#endif

      ulong invUse[4];
      copy4(invUse, dxInv[g]);
      if(is_zero_256(invUse)) {
        uint jAlt = (j + 1u) & (kNbJump - 1u);
#if KANGAROO_METAL_USE_SYMMETRY
        jAlt = jump_next_sym(j, symClassCache[g]);
#endif
        ulong dxAlt[4];
        mod_sub_256_tg(dxAlt, px, tgJumpX[jAlt]);
        if(is_zero_256(dxAlt)) {
          continue;
        }
        mod_inv_pow_k1(invUse, dxAlt);
        if(is_zero_256(invUse)) {
          continue;
        }
        j = jAlt;
      }

      ulong rx[4];
      ulong ry[4];
      point_add_affine_tg(rx, ry, px, py, tgJumpX[j], tgJumpY[j], invUse);

#if KANGAROO_METAL_USE_SYMMETRY
      // 有符号距离累加 + 对称翻转
      dist_add_signed_192(dCache[g], tgJumpD[j][0], tgJumpD[j][1]);
      if(mod_positive_256(ry)) {
        dist_toggle_sign_192(dCache[g]);
        symClassCache[g] ^= 1u;
      }
#else
      ulong carry = 0ull;
      dCache[g][0] = addcarry_u64(dCache[g][0], tgJumpD[j][0], carry);
      dCache[g][1] = addcarry_u64(dCache[g][1], tgJumpD[j][1], carry);
      dCache[g][2] = addcarry_u64(dCache[g][2], 0ull, carry);
#endif

      // Store X/Y every run so following runs observe updated state.
      kangaroos[idx0 + 0u * nt] = rx[0];
      kangaroos[idx0 + 1u * nt] = rx[1];
      kangaroos[idx0 + 2u * nt] = rx[2];
      kangaroos[idx0 + 3u * nt] = rx[3];

      kangaroos[idx0 + 4u * nt] = ry[0];
      kangaroos[idx0 + 5u * nt] = ry[1];
      kangaroos[idx0 + 6u * nt] = ry[2];
      kangaroos[idx0 + 7u * nt] = ry[3];

      if((rx[3] & params.dpMask) == 0ull) {
        uint pos = atomic_fetch_add_explicit(counter, 1u, memory_order_relaxed);
        if(pos < params.maxFound) {
          uint outBase = pos * kItemSize32 + 1u;

          outWords[outBase + 0u] = lo32(rx[0]);
          outWords[outBase + 1u] = hi32(rx[0]);
          outWords[outBase + 2u] = lo32(rx[1]);
          outWords[outBase + 3u] = hi32(rx[1]);
          outWords[outBase + 4u] = lo32(rx[2]);
          outWords[outBase + 5u] = hi32(rx[2]);
          outWords[outBase + 6u] = lo32(rx[3]);
          outWords[outBase + 7u] = hi32(rx[3]);

          outWords[outBase + 8u]  = lo32(dCache[g][0]);
          outWords[outBase + 9u]  = hi32(dCache[g][0]);
          outWords[outBase + 10u] = lo32(dCache[g][1]);
          outWords[outBase + 11u] = hi32(dCache[g][1]);
          outWords[outBase + 12u] = lo32(dCache[g][2]);
          outWords[outBase + 13u] = hi32(dCache[g][2]);

          ulong kIdx = static_cast<ulong>(localTid) +
                       static_cast<ulong>(g) * static_cast<ulong>(nt) +
                       static_cast<ulong>(groupId) * static_cast<ulong>(nt * kGpuGroupSize);

          outWords[outBase + 14u] = lo32(kIdx);
          outWords[outBase + 15u] = hi32(kIdx);
        }
      }
    }
  }

  // Write back D once per launch.
  for(uint g = 0; g < kGpuGroupSize; g++) {
    const uint idx0 = blockBase + g * strideSize + localTid;
    kangaroos[idx0 + 8u * nt]  = dCache[g][0];
    kangaroos[idx0 + 9u * nt]  = dCache[g][1];
    kangaroos[idx0 + 10u * nt] = dCache[g][2];
#if KANGAROO_METAL_USE_SYMMETRY
    kangaroos[idx0 + 11u * nt] = static_cast<ulong>(symClassCache[g]);
#endif
  }

#if KANGAROO_METAL_ENABLE_INV_PROFILE
  if(params.profileMode != 0u) {
    atomic_fetch_add_explicit(&(invProfile[0]), invCalls, memory_order_relaxed);
    atomic_fetch_add_explicit(&(invProfile[1]), invFallback, memory_order_relaxed);
    atomic_fetch_add_explicit(&(invProfile[2]), invIterSum, memory_order_relaxed);
    atomic_fetch_max_explicit(&(invProfile[3]), invIterMax, memory_order_relaxed);
    atomic_fetch_add_explicit(&(invProfile[4]), invFallbackIterLimit, memory_order_relaxed);
    atomic_fetch_add_explicit(&(invProfile[5]), invFallbackGcd, memory_order_relaxed);
    atomic_fetch_add_explicit(&(invProfile[6]), invFallbackNormNeg, memory_order_relaxed);
    atomic_fetch_add_explicit(&(invProfile[7]), invFallbackNormPos, memory_order_relaxed);
  }
#endif
}

// Variant: keep only X coordinates in thread-local cache across nbRun.
// This reduces repeated global X loads vs nocache, while avoiding the full
// px/py/d cache footprint of the default kernel.
kernel void kangaroo_step_nocache_pxcache(device ulong *kangaroos [[buffer(0)]],
                                          device uint *outWords [[buffer(1)]],
                                          constant ulong2 *jumpD [[buffer(2)]],
                                          constant ulong4 *jumpX [[buffer(3)]],
                                          constant ulong4 *jumpY [[buffer(4)]],
                                          constant KernelParams &params [[buffer(5)]],
                                          device atomic_uint *invProfile [[buffer(6)]],
                                          uint localTid [[thread_position_in_threadgroup]],
                                          uint groupId [[threadgroup_position_in_grid]]) {

  if(localTid >= params.nbThreadPerGroup || groupId >= params.nbThreadGroup) {
    return;
  }

  threadgroup ulong tgJumpD[kNbJump][2];
  threadgroup ulong tgJumpX[kNbJump][4];
  threadgroup ulong tgJumpY[kNbJump][4];

  if(localTid < kNbJump) {
    ulong2 d = jumpD[localTid];
    ulong4 x = jumpX[localTid];
    ulong4 y = jumpY[localTid];

    tgJumpD[localTid][0] = d.x;
    tgJumpD[localTid][1] = d.y;

    tgJumpX[localTid][0] = x.x;
    tgJumpX[localTid][1] = x.y;
    tgJumpX[localTid][2] = x.z;
    tgJumpX[localTid][3] = x.w;

    tgJumpY[localTid][0] = y.x;
    tgJumpY[localTid][1] = y.y;
    tgJumpY[localTid][2] = y.z;
    tgJumpY[localTid][3] = y.w;
  }

  threadgroup_barrier(mem_flags::mem_threadgroup);

  const uint nt = params.nbThreadPerGroup;
  const uint blockSize = nt * params.kSize * kGpuGroupSize;
  const uint strideSize = nt * params.kSize;
  const uint blockBase = groupId * blockSize;

  device atomic_uint *counter = reinterpret_cast<device atomic_uint *>(outWords);

  thread ulong pxCache[kGpuGroupSize][4];
  thread ulong dxInv[kGpuGroupSize][4];
  thread ulong prefix[kGpuGroupSize][4];
#if KANGAROO_METAL_USE_SYMMETRY
  thread uint symClassCache[kGpuGroupSize];
#endif
#if KANGAROO_METAL_ENABLE_INV_PROFILE
  uint invCalls = 0u;
  uint invFallback = 0u;
  uint invIterSum = 0u;
  uint invIterMax = 0u;
  uint invFallbackIterLimit = 0u;
  uint invFallbackGcd = 0u;
  uint invFallbackNormNeg = 0u;
  uint invFallbackNormPos = 0u;
#endif

  for(uint g = 0; g < kGpuGroupSize; g++) {
    const uint idx0 = blockBase + g * strideSize + localTid;
    pxCache[g][0] = kangaroos[idx0 + 0u * nt];
    pxCache[g][1] = kangaroos[idx0 + 1u * nt];
    pxCache[g][2] = kangaroos[idx0 + 2u * nt];
    pxCache[g][3] = kangaroos[idx0 + 3u * nt];
#if KANGAROO_METAL_USE_SYMMETRY
    symClassCache[g] = static_cast<uint>(kangaroos[idx0 + 11u * nt]) & 1u;
#endif
  }

  for(uint run = 0; run < kNbRun; run++) {

    for(uint g = 0; g < kGpuGroupSize; g++) {
      uint j = jump_index(pxCache[g][0]);
#if KANGAROO_METAL_USE_SYMMETRY
      j = jump_index_sym(pxCache[g][0], symClassCache[g]);
#endif
      mod_sub_256_tg(dxInv[g], pxCache[g], tgJumpX[j]);
    }

#if KANGAROO_METAL_ENABLE_INV_PROFILE
    mod_inv_grouped(
        dxInv,
        prefix,
        invCalls,
        invFallback,
        invIterSum,
        invIterMax,
        invFallbackIterLimit,
        invFallbackGcd,
        invFallbackNormNeg,
        invFallbackNormPos);
#else
    mod_inv_grouped(dxInv, prefix);
#endif

    for(uint g = 0; g < kGpuGroupSize; g++) {
      const uint idx0 = blockBase + g * strideSize + localTid;

      ulong py[4];
      py[0] = kangaroos[idx0 + 4u * nt];
      py[1] = kangaroos[idx0 + 5u * nt];
      py[2] = kangaroos[idx0 + 6u * nt];
      py[3] = kangaroos[idx0 + 7u * nt];

      ulong d0 = kangaroos[idx0 + 8u * nt];
      ulong d1 = kangaroos[idx0 + 9u * nt];
      ulong d2 = kangaroos[idx0 + 10u * nt];

      uint j = jump_index(pxCache[g][0]);
#if KANGAROO_METAL_USE_SYMMETRY
      j = jump_index_sym(pxCache[g][0], symClassCache[g]);
#endif

      ulong invUse[4];
      copy4(invUse, dxInv[g]);
      if(is_zero_256(invUse)) {
        uint jAlt = (j + 1u) & (kNbJump - 1u);
#if KANGAROO_METAL_USE_SYMMETRY
        jAlt = jump_next_sym(j, symClassCache[g]);
#endif
        ulong dxAlt[4];
        mod_sub_256_tg(dxAlt, pxCache[g], tgJumpX[jAlt]);
        if(is_zero_256(dxAlt)) {
          continue;
        }
        mod_inv_pow_k1(invUse, dxAlt);
        if(is_zero_256(invUse)) {
          continue;
        }
        j = jAlt;
      }

      ulong rx[4];
      ulong ry[4];
      point_add_affine_tg(rx, ry, pxCache[g], py, tgJumpX[j], tgJumpY[j], invUse);

#if KANGAROO_METAL_USE_SYMMETRY
      // 有符号距离累加 + 对称翻转
      dist_add_signed_192(d0, d1, d2, tgJumpD[j][0], tgJumpD[j][1]);
      if(mod_positive_256(ry)) {
        dist_toggle_sign_192(d0, d1, d2);
        symClassCache[g] ^= 1u;
      }
#else
      ulong carry = 0ull;
      d0 = addcarry_u64(d0, tgJumpD[j][0], carry);
      d1 = addcarry_u64(d1, tgJumpD[j][1], carry);
      d2 = addcarry_u64(d2, 0ull, carry);
#endif

      // Keep X in local cache for next run to avoid reloading from global memory.
      pxCache[g][0] = rx[0];
      pxCache[g][1] = rx[1];
      pxCache[g][2] = rx[2];
      pxCache[g][3] = rx[3];

      // Store state so the host and other launches observe progress.
      kangaroos[idx0 + 0u * nt] = rx[0];
      kangaroos[idx0 + 1u * nt] = rx[1];
      kangaroos[idx0 + 2u * nt] = rx[2];
      kangaroos[idx0 + 3u * nt] = rx[3];

      kangaroos[idx0 + 4u * nt] = ry[0];
      kangaroos[idx0 + 5u * nt] = ry[1];
      kangaroos[idx0 + 6u * nt] = ry[2];
      kangaroos[idx0 + 7u * nt] = ry[3];

      kangaroos[idx0 + 8u * nt]  = d0;
      kangaroos[idx0 + 9u * nt]  = d1;
      kangaroos[idx0 + 10u * nt] = d2;
#if KANGAROO_METAL_USE_SYMMETRY
      kangaroos[idx0 + 11u * nt] = static_cast<ulong>(symClassCache[g]);
#endif

      if((rx[3] & params.dpMask) == 0ull) {
        uint pos = atomic_fetch_add_explicit(counter, 1u, memory_order_relaxed);
        if(pos < params.maxFound) {
          uint outBase = pos * kItemSize32 + 1u;

          outWords[outBase + 0u] = lo32(rx[0]);
          outWords[outBase + 1u] = hi32(rx[0]);
          outWords[outBase + 2u] = lo32(rx[1]);
          outWords[outBase + 3u] = hi32(rx[1]);
          outWords[outBase + 4u] = lo32(rx[2]);
          outWords[outBase + 5u] = hi32(rx[2]);
          outWords[outBase + 6u] = lo32(rx[3]);
          outWords[outBase + 7u] = hi32(rx[3]);

          outWords[outBase + 8u]  = lo32(d0);
          outWords[outBase + 9u]  = hi32(d0);
          outWords[outBase + 10u] = lo32(d1);
          outWords[outBase + 11u] = hi32(d1);
          outWords[outBase + 12u] = lo32(d2);
          outWords[outBase + 13u] = hi32(d2);

          ulong kIdx = static_cast<ulong>(localTid) +
                       static_cast<ulong>(g) * static_cast<ulong>(nt) +
                       static_cast<ulong>(groupId) * static_cast<ulong>(nt * kGpuGroupSize);

          outWords[outBase + 14u] = lo32(kIdx);
          outWords[outBase + 15u] = hi32(kIdx);
        }
      }
    }
  }

#if KANGAROO_METAL_ENABLE_INV_PROFILE
  if(params.profileMode != 0u) {
    atomic_fetch_add_explicit(&(invProfile[0]), invCalls, memory_order_relaxed);
    atomic_fetch_add_explicit(&(invProfile[1]), invFallback, memory_order_relaxed);
    atomic_fetch_add_explicit(&(invProfile[2]), invIterSum, memory_order_relaxed);
    atomic_fetch_max_explicit(&(invProfile[3]), invIterMax, memory_order_relaxed);
    atomic_fetch_add_explicit(&(invProfile[4]), invFallbackIterLimit, memory_order_relaxed);
    atomic_fetch_add_explicit(&(invProfile[5]), invFallbackGcd, memory_order_relaxed);
    atomic_fetch_add_explicit(&(invProfile[6]), invFallbackNormNeg, memory_order_relaxed);
    atomic_fetch_add_explicit(&(invProfile[7]), invFallbackNormPos, memory_order_relaxed);
  }
#endif
}

kernel void metal_unit_test(device const MathTestInput *inputs [[buffer(0)]],
                            device MathTestOutput *outputs [[buffer(1)]],
                            constant uint &count [[buffer(2)]],
                            uint gid [[thread_position_in_grid]]) {
  if(gid >= count) {
    return;
  }

  MathTestInput in = inputs[gid];
  MathTestOutput out;
  out.flags = 0u;
  out.pad = 0u;

  ulong a[4] = {in.a[0], in.a[1], in.a[2], in.a[3]};
  ulong b[4] = {in.b[0], in.b[1], in.b[2], in.b[3]};

  ulong mul[4];
  ulong sqr[4];
  ulong inv[4];

  mod_mul_k1(mul, a, b);
  mod_sqr_k1(sqr, a);
  uint invIter = 0u;
  uint invFallback = 0u;
  uint invFallbackReason = 0u;
  mod_inv_k1(inv, a, invIter, invFallback, invFallbackReason);

  out.mul[0] = mul[0];
  out.mul[1] = mul[1];
  out.mul[2] = mul[2];
  out.mul[3] = mul[3];

  out.sqr[0] = sqr[0];
  out.sqr[1] = sqr[1];
  out.sqr[2] = sqr[2];
  out.sqr[3] = sqr[3];

  out.inv[0] = inv[0];
  out.inv[1] = inv[1];
  out.inv[2] = inv[2];
  out.inv[3] = inv[3];

  ulong x[4] = {in.px[0], in.px[1], in.px[2], in.px[3]};
  ulong y[4] = {in.py[0], in.py[1], in.py[2], in.py[3]};
  ulong jx[4] = {in.jx[0], in.jx[1], in.jx[2], in.jx[3]};
  ulong jy[4] = {in.jy[0], in.jy[1], in.jy[2], in.jy[3]};

  ulong dx[4];
  mod_sub_256(dx, x, jx);

  if(is_zero_256(dx)) {
    out.flags |= 1u;
    out.rx[0] = out.rx[1] = out.rx[2] = out.rx[3] = 0ull;
    out.ry[0] = out.ry[1] = out.ry[2] = out.ry[3] = 0ull;
  } else {
    ulong dxInv[4];
    ulong rx[4];
    ulong ry[4];
    uint dxInvIter = 0u;
    uint dxInvFallback = 0u;
    uint dxInvFallbackReason = 0u;
    mod_inv_k1(dxInv, dx, dxInvIter, dxInvFallback, dxInvFallbackReason);
    point_add_affine(rx, ry, x, y, jx, jy, dxInv);

    out.rx[0] = rx[0];
    out.rx[1] = rx[1];
    out.rx[2] = rx[2];
    out.rx[3] = rx[3];

    out.ry[0] = ry[0];
    out.ry[1] = ry[1];
    out.ry[2] = ry[2];
    out.ry[3] = ry[3];
  }

  outputs[gid] = out;
}
