# Metal 设备 Puzzle-135 高位求解完整逻辑分析报告

> 分析日期：2026-02-25
> 分析依据：**仅以代码为唯一参考**，覆盖底层指令集层面
> 范围：Metal GPU 后端 + 断点恢复续跑 + 私钥输出全链路

---

## 目录

1. [架构总览](#1-架构总览)
2. [192位距离编码体系（核心扩展）](#2-192位距离编码体系)
3. [Metal Shader端距离运算深度分析](#3-metal-shader端距离运算)
4. [DP输出格式：Shader端与Host端对齐验证](#4-dp输出格式对齐验证)
5. [kIdx奇偶性与Tame/Wild一致性](#5-kidx奇偶性与tamewild一致性)
6. [断点恢复续跑逻辑](#6-断点恢复续跑逻辑)
7. [私钥还原链路](#7-私钥还原链路)
8. [边界情况与潜在问题清单](#8-边界情况与潜在问题清单)
9. [综合结论](#9-综合结论)

---

## 1. 架构总览

### 1.1 Metal 后端整体流程（puzzle135 路径）

```
main.cpp:354 → Run() → [InitRange / InitSearchKey / CreateJumpTable]
  ↓
SolveKeyGPU() [Kangaroo.cpp:566]
  → GPUEngine(Metal) 构造 [GPUEngineMetal.mm:579]
  → CreateHerd() 或从 workfile 恢复 kangaroo 状态
  → SetParams / SetKangaroos [GPUEngineMetal.mm:1176]
  → callKernel() 首次提交 [GPUEngineMetal.mm:1513]
  → 主循环：Launch() → 解析 DP → AddToTable() → CollisionCheck() → CheckKey()
  → 保存请求时：GetKangaroos() → SaveWork()
  → 找到后：Output() 输出私钥
```

### 1.2 关键编译条件

- `USE_SYMMETRY`：影响距离编码（128→192 bit）、`KSIZE`（11→12）、symClass 持久化
- `WITHMETAL`（macOS）：编译 `GPUEngineMetal.mm` + `KangarooMetal.metal`

---

## 2. 192位距离编码体系

### 2.1 HashTable 端的 int192_t 格式

**文件**: `Kangaroo/HashTable.h:55-64`（union 定义）

```
int192_t 布局（3 × uint64，全局bit位置）：
  bit 191  = i64[2] bit 63 = 符号位 (0=正距离, 1=负距离)
  bit 190  = i64[2] bit 62 = kangaroo类型 (0=Tame, 1=Wild)
  bit 189-0 = 距离量级（190位有效幅值）
```

**编码函数**: `HashTable::Convert()` [HashTable.cpp:82]

```cpp
void HashTable::Convert(Int *x,Int *d,uint32_t type,uint64_t *h,int128_t *X,int192_t *D) {
  uint64_t sign = 0;
  uint64_t type64 = (uint64_t)type << 62;  // type放入bit 62

  // 概率失败(1/2^192)：d.bits64[3] > 0x7FFF...时(d为负)
  if(d->bits64[3] > 0x7FFFFFFFFFFFFFFFULL) {
    Int N(d); N.ModNegK1order();
    D->i64[0] = N.bits64[0]; D->i64[1] = N.bits64[1];
    D->i64[2] = N.bits64[2] & 0x3FFFFFFFFFFFFFFFULL;  // 清除bit62,63
    sign = 1ULL << 63;  // 设置符号位
  } else {
    D->i64[0] = d->bits64[0]; D->i64[1] = d->bits64[1];
    D->i64[2] = d->bits64[2] & 0x3FFFFFFFFFFFFFFFULL;  // 清除bit62,63
  }
  D->i64[2] |= sign;    // 写符号位（bit 63）
  D->i64[2] |= type64;  // 写类型位（bit 62）
  *h = (x->bits64[2] & HASH_MASK);  // hash桶用x坐标中间64位
}
```

**解码函数**: `HashTable::CalcDistAndType()` [HashTable.cpp:258]

```cpp
void HashTable::CalcDistAndType(int192_t d,Int* kDist,uint32_t* kType) {
  *kType = (d.i64[2] & 0x4000000000000000ULL) != 0;  // 提取bit62 = 类型
  int sign = (d.i64[2] & 0x8000000000000000ULL) != 0;  // 提取bit63 = 符号
  d.i64[2] &= 0x3FFFFFFFFFFFFFFFULL;  // 清除bit62,63，保留190位幅值
  kDist->SetInt32(0);
  kDist->bits64[0] = d.i64[0]; kDist->bits64[1] = d.i64[1];
  kDist->bits64[2] = d.i64[2];
  if(sign) kDist->ModNegK1order();  // 符号为负则取模负
}
```

**结论**：编码/解码对称，无问题。

---

### 2.2 GPU端（Host↔Metal）距离编码

**文件**: `GPU/GPUEngine.h:40-84`

```cpp
static inline constexpr uint64_t kGpuDistSignBit = 1ULL << 63;

// Host→GPU 上传编码
static inline void EncodeGpuDistanceSym(Int *dist, uint64_t *d0, uint64_t *d1, uint64_t *d2) {
  // 若 dist 为负(bits64[3] > 0x7FFF...)：取模负后，设置符号位
  // 普通情况：*d2 = absDist.bits64[2] & ~kGpuDistSignBit (清除bit63)
  // 注意：GPU端 d[2] 的 bit62 作为幅值的一部分（不存类型）
}

// GPU→Host 回读解码
static inline void DecodeGpuDistanceSym(uint64_t d0, uint64_t d1, uint64_t d2, Int *dist) {
  uint64_t mag2 = d2 & ~kGpuDistSignBit;  // 清除bit63，保留bit62（幅值高位）
  dist->bits64[0] = d0; dist->bits64[1] = d1; dist->bits64[2] = mag2;
  if((d2 & kGpuDistSignBit) != 0ULL && ...) dist->ModNegK1order();
}
```

**关键特性**：
- GPU 距离格式中：bit 63 of d[2] = 符号位；bit 62 of d[2] = **幅值高位**（非类型）
- HashTable 格式中：bit 62 of i64[2] = 类型位
- 当 GPU DP 被存入 HashTable 时，`HashTable::Convert()` 会将 bit62 **覆盖**为 kType
- 因此 GPU 幅值中的 bit62 信息在存入 HashTable 时被丢弃，但无影响（puzzle135 距离最大约 2^68，远低于 2^190）

---

## 3. Metal Shader端距离运算

### 3.1 有符号加法 `dist_add_signed_192` [KangarooMetal.metal:793]

```metal
inline void dist_add_signed_192(thread ulong &d0, thread ulong &d1, thread ulong &d2,
                                 ulong jmp0, ulong jmp1) {
  ulong signBit = d2 & kDistSignBit;  // kDistSignBit = 1ull << 63
  d2 &= ~kDistSignBit;  // 提取幅值高位

  if(signBit == 0ull) {
    // 正距离: |d| += jmp (三步进位链)
    ulong carry = 0ull;
    d0 = addcarry_u64(d0, jmp0, carry);
    d1 = addcarry_u64(d1, jmp1, carry);
    d2 = addcarry_u64(d2, 0ull, carry);  // 进位传入幅值高位
  } else {
    // 负距离: |d| -= jmp (三步借位链)
    ulong borrow = 0ull;
    ulong r0 = subborrow_u64(d0, jmp0, borrow);
    ulong r1 = subborrow_u64(d1, jmp1, borrow);
    ulong r2 = subborrow_u64(d2, 0ull, borrow);
    if(borrow != 0ull) {
      // |d| < jmp：结果变正，|result| = jmp - |d|
      borrow = 0ull;
      d0 = subborrow_u64(jmp0, d0, borrow);  // d0,d1,d2 未被r0-r2覆盖，仍是原始值
      d1 = subborrow_u64(jmp1, d1, borrow);
      d2 = subborrow_u64(0ull, d2, borrow);   // 0 - 0 - borrow
      signBit = 0ull;  // 符号变正
    } else {
      d0 = r0; d1 = r1; d2 = r2;
    }
  }
  if((d0 | d1 | d2) == 0ull) signBit = 0ull;  // 规范化 -0 → +0
  d2 |= signBit;
}
```

**正确性分析**：
- 跳步距离 jmp 最大 128 位（jumpBit ≤ 128），即 jmp2 = 0
- 当 |d| < jmp 时，d2 必为 0（否则 |d| ≥ 2^128 > jmp）
- 此时 `subborrow_u64(0, 0, borrow)` 中：若 borrow_from_d1=1，则 d2 = 0 - 0 - 1 = 0xFFFFFFFFFFFFFFFF —— 但这不可能发生，因为 jmp > |d| 且两者都是 128 位，d1 的借位必定不会传入 d2
- 结论：**该函数数学上正确**

### 3.2 符号翻转 `dist_toggle_sign_192` [KangarooMetal.metal:837]

```metal
inline void dist_toggle_sign_192(thread ulong &d0, thread ulong &d1, thread ulong &d2) {
  if((d0 | d1 | (d2 & ~kDistSignBit)) == 0ull) {
    d2 &= ~kDistSignBit;  // 零规范化为 +0
  } else {
    d2 ^= kDistSignBit;   // 仅翻转 bit63
  }
}
```

**关键点**：
- 仅翻转 bit63（符号位），不做模运算
- 零值规范化检查正确（排除符号位后检查其余全零）
- 与 CPU 端 `ModNegK1order()` 不等价，但两者在 CheckKey 的四种等价验证中均可被覆盖

### 3.3 Y坐标正负性检测 `mod_positive_256` [KangarooMetal.metal:719]

```metal
inline bool mod_positive_256(thread ulong r[4]) {
  if(r[3] > 0x7FFFFFFFFFFFFFFFull) {  // 检查最高64位limb
    ulong t[4];
    mod_neg_256(t, r);  // r = p - r（mod p）
    copy4(r, t);
    return true;
  }
  return false;
}
```

**与CPU端 `ModPositiveK1()` 的对比**（CPU代码 [IntMod.cpp:1219]）：

```cpp
uint32_t Int::ModPositiveK1() {
  Int N(this); Int D(this);
  N.ModNeg();       // N = p - this
  D.Sub(&N);        // D = this - (p - this) = 2*this - p
  if(D.IsNegative()) return 0;  // this < p/2：不翻转
  Set(&N); return 1;            // this ≥ p/2：翻转
}
```

**⚠️ 发现差异（轻微但需记录）**：
- CPU 使用 `2*this - p < 0` 的精确判断：当 `Y ≥ (p+1)/2` 时翻转
- Metal 使用 `r[3] > 0x7FFFFFFFFFFFFFFF`：当 `Y ≥ 2^255` 时翻转
- `p/2 ≈ 2^255 - 2^31`，因此存在 Y 值区间 `[p/2, 2^255)` 使得：
  - CPU 判定"负"（应翻转）：Y 的 bits64[3] = 0x7FFFFFFFFFFFFFFF 且低位足够大
  - Metal 判定"正"（不翻转）

**影响分析**：
- 这是一个**近似判断**而非精确判断
- 影响区间极窄（约 2^(256-64) = 2^192 分之一的 Y 值处于此区间）
- Metal Kangaroo 与 CPU Kangaroo 在极少数情况下会采用不同的符号约定
- 但 `CheckKey()` 尝试所有 4 种符号组合（type=0,1,2,3），**不影响最终找到正确私钥**
- GPU 内部状态保持自洽，不会出现"循环反转"

---

## 4. DP输出格式对齐验证

### 4.1 Metal Shader 端输出编码 [KangarooMetal.metal:1677-1704]

```metal
uint outBase = pos * kItemSize32 + 1u;  // 跳过计数器，kItemSize32=16

// X坐标 (256位 = 8个uint32)
outWords[outBase + 0u] = lo32(rx[0]); outWords[outBase + 1u] = hi32(rx[0]);
outWords[outBase + 2u] = lo32(rx[1]); outWords[outBase + 3u] = hi32(rx[1]);
outWords[outBase + 4u] = lo32(rx[2]); outWords[outBase + 5u] = hi32(rx[2]);
outWords[outBase + 6u] = lo32(rx[3]); outWords[outBase + 7u] = hi32(rx[3]);

// 距离d (192位 = 6个uint32)
outWords[outBase + 8u]  = lo32(dCache[g][0]); outWords[outBase + 9u]  = hi32(dCache[g][0]);
outWords[outBase + 10u] = lo32(dCache[g][1]); outWords[outBase + 11u] = hi32(dCache[g][1]);
outWords[outBase + 12u] = lo32(dCache[g][2]); outWords[outBase + 13u] = hi32(dCache[g][2]);

// kIdx (64位 = 2个uint32)
ulong kIdx = localTid + g * params.nbThreadPerGroup +
             groupId * (params.nbThreadPerGroup * kGpuGroupSize);
outWords[outBase + 14u] = lo32(kIdx); outWords[outBase + 15u] = hi32(kIdx);
```

### 4.2 Host 端解析 [GPUEngineMetal.mm:1717-1745]

```cpp
uint32_t *itemPtr = doneOutput + (i * ITEM_SIZE32 + 1);
it.kIdx = *((uint64_t *)(itemPtr + 14));     // 读取 [14,15] = kIdx ✓

uint64_t *x = (uint64_t *)itemPtr;
it.x.bits64[0] = x[0];  // 读取 [0,1] as uint64 → rx[0] ✓
it.x.bits64[1] = x[1];  // 读取 [2,3] as uint64 → rx[1] ✓
it.x.bits64[2] = x[2];  // 读取 [4,5] as uint64 → rx[2] ✓
it.x.bits64[3] = x[3];  // 读取 [6,7] as uint64 → rx[3] ✓
it.x.bits64[4] = 0;

uint64_t *d = (uint64_t *)(itemPtr + 8);
DecodeGpuDistanceSym(d[0], d[1], d[2], &it.d);  // 读取 [8-9,10-11,12-13] ✓
```

**结论**：**Shader 端输出格式与 Host 端解析完全对齐，无偏移错误**。

小端序（GPU buffer 是 uint32 数组），Host 端将两个相邻 uint32 合并为 uint64，字节序一致（均为小端）。

---

## 5. kIdx奇偶性与Tame/Wild一致性

### 5.1 初始化逻辑 [Kangaroo.cpp:609-622]

```cpp
uint64_t nbThreadGroup = nbThread / nbThreadPerGroup;
uint64_t walkersPerBlock = nbThreadPerGroup * gpuGroupSize;
for(uint64_t b = 0; b < nbThreadGroup; b++) {
  uint64_t blockBase = b * walkersPerBlock;
  for(int g = 0; g < gpuGroupSize; g++) {
    uint64_t base = blockBase + g * nbThreadPerGroup;
    CreateHerd(nbThreadPerGroup, &px[base], &py[base], &d[base], TAME);
  }
}
```

`CreateHerd(n, ..., TAME)` 内部：奇偶性由 `(j + TAME) % 2` 决定，j 从 0 递增：
- j=0 → TAME（偶数 index）
- j=1 → WILD（奇数 index）

由于 nbThreadPerGroup 通常为 256（偶数），blockBase 和每个 base 均为偶数，因此：

```
kangaroo[base + j].type = j % 2 == 0 ? TAME : WILD
base + j 的奇偶性 = j 的奇偶性（因 base 为偶数）
```

### 5.2 Shader 端 kIdx 公式 [KangarooMetal.metal:1698-1701]

```metal
ulong kIdx = localTid + g * nbThreadPerGroup + groupId * (nbThreadPerGroup * kGpuGroupSize);
```

对应关系：
```
kIdx % 2 = (localTid + g * nbThreadPerGroup + ...) % 2
         = localTid % 2（当 nbThreadPerGroup 为偶数时）
         = 与 CPU 初始化的类型一致：偶数=TAME, 奇数=WILD
```

### 5.3 Host 端 kType 提取 [Kangaroo.cpp:699]

```cpp
uint32_t kType = (uint32_t)(gpuFound[g].kIdx % 2);  // 从 kIdx 提取类型
```

**结论**：**kIdx % 2 与 CreateHerd 的初始 Tame/Wild 分配完全一致**，前提是 nbThreadPerGroup 为偶数（Metal 默认 256，始终成立）。

---

## 6. 断点恢复续跑逻辑

### 6.1 工作文件版本检查 [Backup.cpp:200-221]

```cpp
loadedWorkVersion = version;
loadedWorkHasSymClass = (loadedWorkVersion >= 1);

#ifdef USE_SYMMETRY
if(loadedWorkVersion < 2) {
  printf("LoadWork: ERROR - version %d uses 128-bit distance (incompatible).\n", version);
  fclose(fRead); fRead = NULL;
  return false;  // 强制中止，不允许静默兼容
}
```

**版本对应**：
- v0：128位距离，无 symClass（废弃）
- v1：128位距离，有 symClass（禁止在 USE_SYMMETRY 编译下加载）
- v2：192位距离 + symClass（当前格式，USE_SYMMETRY 要求）

**潜在问题**：若用旧版本（v1）工作文件续跑 USE_SYMMETRY 编译的程序，将直接报错退出，**不会产生静默数据腐化**。

### 6.2 Kangaroo 状态恢复流程

#### FetchWalks [Backup.cpp:241-273]

```cpp
for(n = 0; n < nbWalk && nbLoadedWalk > 0; n++) {
  fread(&x[n].bits64, 32, 1, fRead); x[n].bits64[4] = 0;  // bits64[4]必须清零！
  fread(&y[n].bits64, 32, 1, fRead); y[n].bits64[4] = 0;
  fread(&d[n].bits64, 32, 1, fRead); d[n].bits64[4] = 0;
  if(loadedWorkHasSymClass) {
    uint64_t sc = 0;
    fread(&sc, sizeof(uint64_t), 1, fRead);
    if(symClass != NULL) symClass[n] = sc & 1ULL;  // 只取最低位
  } else if(symClass != NULL) {
    symClass[n] = 0ULL;  // 旧文件无 symClass，初始化为0
  }
  nbLoadedWalk--;
}
// 不足时用 CreateHerd(TAME) 补充
if(n < nbWalk) CreateHerd(empty, x+n, y+n, d+n, TAME);
```

**重要细节**：
- `bits64[4]` 必须显式清零（Int 类有5个 uint64 槽位，第5个是溢出缓冲区）
- symClass 只取 bit0
- 不足的 kangaroo 以 TAME 类型补充（symClass=0）

#### FectchKangaroos [Backup.cpp:342-445]

```cpp
// USE_SYMMETRY 下为 GPU 线程分配 symClass 数组
threads[id].symClass = new uint64_t[n];
FetchWalks(n, threads[id].px, threads[id].py, threads[id].distance, threads[id].symClass);
```

#### SetKangaroos 上传到 GPU [GPUEngineMetal.mm:1176-1239]

```cpp
uint64_t sc = (symClass != nullptr) ? (symClass[idx] & 1ULL) : 0ULL;
inputKangarooPinned[g*strideSize + t + 11*nbThreadPerGroup] = sc;  // field 11
```

**如果 symClass 为 nullptr（首次运行）**：sc = 0，所有 kangaroo 初始 symClass = 0。首次运行时 ph->symClass 未分配（TH_PARAM 被 memset 为 0），这是正确的初始状态。

#### 保存时回读 [Kangaroo.cpp:752-762]

```cpp
if(saveKangaroo) {
#if defined(USE_SYMMETRY)
  if(ph->symClass == NULL) {
    ph->symClass = new uint64_t[ph->nbKangaroo];  // 懒分配
  }
#endif
  gpu->GetKangaroos(ph->px, ph->py, ph->distance, ph->symClass);
}
ph->isWaiting = true; LOCK(saveMutex); ph->isWaiting = false; UNLOCK(saveMutex);
```

**延迟分配**：ph->symClass 在首次保存时才分配。之后由 GetKangaroos 正确回填。

#### GetKangaroos 回读 [GPUEngineMetal.mm:1380-1449]

```cpp
// 解码192位有符号距离
DecodeGpuDistanceSym(
  inputKangarooPinned[... + 8*nbThreadPerGroup],
  inputKangarooPinned[... + 9*nbThreadPerGroup],
  inputKangarooPinned[... + 10*nbThreadPerGroup],
  &dOff);
d[idx].Set(&dOff);
// 回读 symClass
symClass[idx] = inputKangarooPinned[... + 11*nbThreadPerGroup] & 1ULL;
```

**结论**：**断点恢复逻辑完整，符号距离和 symClass 均正确持久化与恢复**。

### 6.3 保存与续跑中的 symClass 数据流完整路径

```
GPU buffer(field 11) → GetKangaroos → ph->symClass[n]
  → SaveWork() → fwrite(sc & 1) → workfile

workfile → fread(sc) → symClass[n] = sc & 1 → ph->symClass[n]
  → SetKangaroos → GPU buffer(field 11)
```

链路完整，无数据丢失。

---

## 7. 私钥还原链路

### 7.1 InitSearchKey 目标公钥平移 [Kangaroo.cpp:1044]

```cpp
void Kangaroo::InitSearchKey() {
  Int SP;
  SP.Set(&rangeStart);
#ifdef USE_SYMMETRY
  SP.ModAddK1order(&rangeWidthDiv2);  // SP = rangeStart + N/2
#endif
  if(!SP.IsZero()) {
    Point RS = secp->ComputePublicKey(&SP);
    RS.y.ModNeg();  // RS = -(SP * G)
    keyToSearch = secp->AddDirect(keysToSearch[keyIdx], RS);  // Q - SP*G
  } else {
    keyToSearch = keysToSearch[keyIdx];
  }
  keyToSearchNeg = keyToSearch;
  keyToSearchNeg.y.ModNeg();
}
```

搜索问题被变换为：找 k' 使 k'*G = keyToSearch = Q - SP*G，其中 SP = rangeStart [+ N/2]。

### 7.2 CheckKey 私钥还原 [Kangaroo.cpp:252-287]

```cpp
bool Kangaroo::CheckKey(Int d1, Int d2, uint8_t type) {
  // 符号修正（尝试4种等价：type=0,1,2,3）
  if(type & 0x1) d1.ModNegK1order();  // bit0: d1取反
  if(type & 0x2) d2.ModNegK1order();  // bit1: d2取反

  Int pk(&d1);
  pk.ModAddK1order(&d2);  // pk = ±d1 + ±d2

  Point P = secp->ComputePublicKey(&pk);  // P = pk * G

  if(P.equals(keyToSearch)) {
    // 找到！还原原始私钥
#ifdef USE_SYMMETRY
    pk.ModAddK1order(&rangeWidthDiv2);  // 第1步: 加回 N/2
#endif
    pk.ModAddK1order(&rangeStart);      // 第2步: 加回起始范围
    return Output(&pk, 'N', type);
  }

  if(P.equals(keyToSearchNeg)) {
    // 找到负数点（公钥的负）
    pk.ModNegK1order();  // 先取反
#ifdef USE_SYMMETRY
    pk.ModAddK1order(&rangeWidthDiv2);  // 第1步: 加回 N/2
#endif
    pk.ModAddK1order(&rangeStart);      // 第2步: 加回起始范围
    return Output(&pk, 'S', type);
  }
  return false;
}
```

**还原数学正确性**：

设目标私钥为 K，K ∈ [rangeStart, rangeEnd]，SP = rangeStart + N/2（对称模式）。

变换后问题：找 k' = K - SP 使得 k'*G = keyToSearch。

碰撞给出：d_tame * G = keyToSearch + d_wild * G（即 (d_tame - d_wild) * G = keyToSearch）

因此 k' = d_tame - d_wild（某种符号组合下成立）。

CheckKey 尝试 pk = ±d1 ± d2，当 pk = k' = K - SP 时：

```
K = pk + SP = pk + rangeStart + N/2
  = (pk + N/2) + rangeStart   ← USE_SYMMETRY 路径
  = pk + rangeStart            ← 非对称路径
```

代码中先加 rangeWidthDiv2 再加 rangeStart，顺序正确。

### 7.3 CollisionCheck 流程 [Kangaroo.cpp:289-355]

```cpp
if(type1 == type2) return false;  // 同 herd 碰撞（Tame-Tame 或 Wild-Wild）忽略

// 分离 Tame/Wild 距离
if(type1 == TAME) { Td = d1; Wd = d2; } else { Td = d2; Wd = d1; }

// 尝试4种等价情况
endOfSearch = CheckKey(Td, Wd, 0) || CheckKey(Td, Wd, 1)
           || CheckKey(Td, Wd, 2) || CheckKey(Td, Wd, 3);
```

**结论**：**4种符号组合覆盖了所有可能，即使 GPU 端的符号约定与 CPU 略有不同，也能找到正确答案**。

---

## 8. 边界情况与潜在问题清单

### 8.1 已确认正确的机制

| 编号 | 项目 | 位置 | 状态 |
|------|------|------|------|
| C1 | DP 输出字段顺序 Shader↔Host 对齐 | metal:1682-1704 ↔ mm:1717-1745 | ✅ 正确 |
| C2 | kIdx % 2 ↔ Tame/Wild 一致性 | cpp:609-621, cpp:699 | ✅ 正确（nbThreadPerGroup 为偶数保证） |
| C3 | 192位距离符号位全链路一致 | bit63 of d[2] = 全局 bit191 | ✅ 正确 |
| C4 | CheckKey 中加回顺序 | 先 rangeWidthDiv2 再 rangeStart | ✅ 正确 |
| C5 | bits64[4] 清零防溢出 | fread 后即 .bits64[4]=0 | ✅ 正确 |
| C6 | symClass 懒分配 + 正确回填 | cpp:753-756, mm:1441 | ✅ 正确 |
| C7 | SetKangaroo 重置后 symClass=0 | cpp:736 | ✅ 正确（GPU 随后自动调整） |
| C8 | workfile 版本 v<2 强制退出 | Backup.cpp:204-211 | ✅ 防止 silent corruption |
| C9 | dist_add_signed_192 边界（d2=0 时借位） | metal:793 | ✅ 数学正确 |
| C10 | 零值规范化 -0→+0 | metal:824-827 | ✅ 正确 |
| C11 | GPU distance 不含 kType bit | GPUEngine.h:66 | ✅ 正确（type 由 kIdx%2 单独传） |

### 8.2 已识别的近似差异（不影响正确性）

| 编号 | 项目 | 位置 | 影响 |
|------|------|------|------|
| A1 | mod_positive_256 使用 `r[3] > 0x7FFF...` 近似 | metal:720 | Y 在 [p/2, 2^255) 的极少数点不被翻转；CheckKey 四种组合兜底，**不影响找到正确密钥** |
| A2 | 距离编码概率失败路径 (1/2^192) | GPUEngine.h:55-68 | 极低概率发生 ModNeg；若发生，在 CheckKey 中也能被 type=1/2/3 覆盖 |

### 8.3 需要注意的细节

| 编号 | 项目 | 位置 | 建议 |
|------|------|------|------|
| N1 | DP buffer 溢出丢失警告 | mm:1707-1712 | 若出现 "items lost" 警告，应增大 -d 或减小 -g，否则漏掉 DP 会降低收敛速度 |
| N2 | 保存超时 (-wt) | Thread.cpp / Backup.cpp:546 | 若超时则本次保存放弃（不写盘），但不影响继续运行；15s 默认值足够 |
| N3 | 旧版 symClass=0 恢复 | Backup.cpp:259 | v1 或 v0 文件中 symClass 恢复为 0，导致恢复后与保存时的 symClass 不一致，但对于 USE_SYMMETRY 编译已阻止加载 v0/v1，无实际影响 |
| N4 | 首次运行 ph->symClass=NULL → SetKangaroos | cpp:637 | 正确：symClass 为 NULL 时 GPU 全部初始化为 0 |
| N5 | kDistTypeBit 已定义但未用于运算 | metal:733 附近 | 仅作常量注释，无实际调用，无害 |
| N6 | stateCache mode 4/5（Jacobian/SIMD）在 sym 路径不生效 | mm:639-641 | mode 5 被强制降级为 mode 1，无需担心，已有保护 |

---

## 9. 综合结论

### 9.1 求解正确性

**Metal 设备求解 puzzle-135（高位 135 位）的整体逻辑是正确的**，具体体现在：

1. **192位距离**完整贯穿 GPU（Shader + Host编解码）和 CPU（HashTable + CheckKey），bit 布局一致
2. **DP输出格式**（X 256位 + d 192位 + kIdx 64位）在 Shader 端与 Host 端严格对齐
3. **kIdx % 2 → Tame/Wild** 在 nbThreadPerGroup 为偶数时完全正确
4. **私钥还原**路径 `(±d_tame ± d_wild) + rangeWidthDiv2 + rangeStart` 数学正确，顺序无误
5. **mod_positive_256 近似**不破坏正确性，CheckKey 的 4 种等价尝试提供了充足容错

### 9.2 断点恢复正确性

**断点恢复续跑逻辑完整**：

1. workfile 版本保护（v<2 强制退出）防止 128bit/192bit 混用
2. symClass 从 GPU buffer 回读 → 写入 workfile → 加载时还原 → 重新上传 GPU，链路无断点
3. bits64[4] 清零防止 Int 类溢出缓冲区污染
4. 不足的 kangaroo 以 TAME 类型补充，符合算法预期

### 9.3 私钥输出正确性

**求解成功后私钥输出路径正确**：

```
碰撞 → CollisionCheck → CheckKey(type=0,1,2,3)
  → P = pk*G == keyToSearch 或 keyToSearchNeg
  → [USE_SYMMETRY] pk += rangeWidthDiv2
  → pk += rangeStart
  → Output(pk) → 打印 + 写入 -o 文件
```

最终 pk 即为目标私钥 K，可通过 `pk*G == 原始目标公钥` 验证。

### 9.4 一处代码注释错误（不影响功能）

`KangarooMetal.metal:733` 注释写 `d1 的 bit 63 = 全局 bit 127`，为旧版 128bit 方案注释残留，**实际 kDistSignBit 应用于 d2**（全局 bit 191），代码逻辑正确，仅注释过时。

---

*分析完成于 2026-02-25，基于 worktree: goofy-merkle*
