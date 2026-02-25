# Kangaroo BTC Puzzle 求解器算法技术文档

> **版本说明**：本文档基于源代码直接分析（2026年2月），覆盖 Metal 移植版本（含192位距离升级）。所有代码片段均标注文件路径和行号，以源码为唯一权威参考。

---

## 目录

1. [项目概述与架构](#1-项目概述与架构)
2. [Pollard Kangaroo 算法原理](#2-pollard-kangaroo-算法原理)
3. [核心数据结构](#3-核心数据结构)
4. [CPU 底层实现——大整数与模运算](#4-cpu-底层实现大整数与模运算)
5. [CUDA GPU 实现](#5-cuda-gpu-实现)
6. [Metal GPU 实现（Apple Silicon）](#6-metal-gpu-实现apple-silicon)
7. [跨平台统一执行框架](#7-跨平台统一执行框架)
8. [工作文件格式与持久化](#8-工作文件格式与持久化)
9. [对称优化（USE_SYMMETRY）详解](#9-对称优化use_symmetry详解)
10. [高位 Puzzle（135位）支持与限制](#10-高位-puzzle135位支持与限制)
11. [附录：关键常量速查表](#11-附录关键常量速查表)

---

## 1. 项目概述与架构

### 1.1 求解目标

本项目针对比特币 Puzzle 挑战，通过 **Pollard Kangaroo 算法**求解有界范围内的椭圆曲线离散对数问题（ECDLP）：

$$\text{已知：} P = k \cdot G,\quad k \in [\text{rangeStart},\ \text{rangeEnd}] \quad \Rightarrow \quad \text{求：} k$$

其中 $G$ 为 secp256k1 曲线生成点，$P$ 为给定的目标公钥。

项目发展脉络：**原版 Jean-Luc PONS Kangaroo** → CUDA 深度优化 → Metal 移植（Apple Silicon）+ 192 位距离升级（支持 puzzle135 等高位谜题）。

### 1.2 命令行参数

来源：[`main.cpp:33-66`](GPU/../main.cpp)

| 参数 | 类型 | 含义 |
|------|------|------|
| `-t nbThread` | CPU | CPU 线程数（默认为系统核数）|
| `-d dpBit` | 算法 | Distinguished Point 前导零位数 |
| `-m maxStep` | 算法 | 最大步数倍数（超时放弃，默认无限）|
| `-gpu` | GPU | 启用 GPU 加速 |
| `-gpuId id1,id2` | GPU | 指定 GPU 设备编号 |
| `-g g1x,g1y[,...]` | GPU | GPU Kernel 网格尺寸 |
| `-w workfile` | 持久化 | 工作文件保存路径 |
| `-i workfile` | 持久化 | 从工作文件恢复并继续 |
| `-wi interval` | 持久化 | 保存间隔（秒）|
| `-ws` | 持久化 | 同时保存袋鼠状态（支持断点续跑）|
| `-wt timeout` | 持久化 | 保存超时（毫秒，默认 3000）|
| `-wm file1 file2 dest` | 工具 | 合并两个工作文件 |
| `-wmdir dir dest` | 工具 | 批量合并目录中的工作文件 |
| `-winfo file` | 工具 | 显示工作文件元信息 |
| `-wcheck file` | 工具 | 校验工作文件完整性 |
| `-s` | 网络 | 启动 Server 模式（分布式）|
| `-c server_ip` | 网络 | 以 Client 模式连接服务器 |
| `-sp port` | 网络 | Server 端口（默认 17403）|
| `-o fileName` | 输出 | 结果输出文件 |
| `-check` | 调试 | GPU Kernel 与 CPU 结果对比验证 |

### 1.3 目录结构

```
Kangaroo/
├── main.cpp                   # 程序入口，参数解析
├── Kangaroo.{h,cpp}           # 核心算法调度（1236 行）
├── Thread.cpp                 # 线程管理，速率统计
├── Backup.cpp                 # 工作文件保存/恢复
├── HashTable.{h,cpp}          # DP 碰撞哈希表
├── Check.cpp                  # GPU/CPU 结果验证
├── Merge.cpp                  # 工作文件合并
├── Network.cpp                # 分布式客户端/服务器
├── GPU/
│   ├── GPUEngine.h            # GPU 引擎接口定义
│   ├── GPUEngine.cu           # CUDA 实现（803 行）
│   ├── GPUEngineMetal.mm      # Metal 封装层（Objective-C++）
│   ├── KangarooMetal.metal    # Metal Shader（3191 行）
│   └── GPUMath.h              # CUDA PTX 宏与数学库（1310 行）
└── SECPK1/
    ├── Int.{h,cpp}            # 256/320 位大整数
    ├── IntGroup.{h,cpp}       # 批量模逆元
    ├── IntMod.cpp             # Montgomery 模运算，DivStep62
    └── SECP256K1.{h,cpp}      # secp256k1 曲线，公钥计算
```

---

## 2. Pollard Kangaroo 算法原理

### 2.1 算法核心思想

Pollard Kangaroo 算法通过两类随机游走（Tame 和 Wild 袋鼠）在椭圆曲线群上跳跃，利用生日悖论产生碰撞，从而还原离散对数。

- **Tame 袋鼠**（驯服）：从已知距离 $d$ 的点 $d \cdot G$ 出发，距离 $d$ 在 $[0, N]$ 内均匀随机
- **Wild 袋鼠**（野生）：从目标公钥 $P$ 附近出发，初始距离相对搜索中点

碰撞条件：当 Tame 袋鼠到达坐标 $(x, y)$，Wild 袋鼠也到达同一坐标时：

$$d_{tame} \cdot G = P + d_{wild} \cdot G \implies k = d_{tame} - d_{wild}$$

### 2.2 Distinguished Point（DP）检测

来源：[`Kangaroo.cpp:190-213`](Kangaroo.cpp)

并非每一步都检查碰撞，而是只在满足 DP 条件时才记录：

```cpp
bool Kangaroo::IsDP(uint64_t x) {
  return (x & dMask) == 0;
}

void Kangaroo::SetDP(int size) {
  dpSize = size;
  if(dpSize == 0) {
    dMask = 0;
  } else {
    if(dpSize > 64) dpSize = 64;
    dMask = (1ULL << (64 - dpSize)) - 1;
    dMask = ~dMask;          // 高 dpSize 位全为 1 的掩码
  }
}
```

**检测条件**：当前袋鼠的 X 坐标（最高 64 位 `bits64[3]`）与 `dMask` 按位与为 0，即 X 坐标最高 `dpSize` 位全为 0。

**DP 参数建议公式**：`dpSize ≈ rangePower/2 - log2(totalWalkers)`，使 DP overhead 低于 5%。

### 2.3 跳跃表构造

来源：[`Kangaroo.cpp:887-977`](Kangaroo.cpp)

跳跃表包含 `NB_JUMP=32` 个预计算的椭圆曲线点及其对应距离：

```cpp
void Kangaroo::CreateJumpTable() {
  // 常量种子：保证不同机器的工作文件跳跃表兼容
  rseed(0x600DCAFE);

  // 非对称模式：jumpBit = rangePower/2 + 1
  // 对称模式：  jumpBit = rangePower/2
  int jumpBit = rangePower / 2 + 1;
  if(jumpBit > 128) jumpBit = 128;
  // ...
```

**跳跃步长选择**（每步根据当前点 X 坐标低位决定）：

```
非对称：jmp = px.bits64[0] % NB_JUMP
对称：  jmp = px.bits64[0] % (NB_JUMP/2) + (NB_JUMP/2) * symClass
```

**对称模式下的特殊构造**（`Kangaroo.cpp:908-963`）：

将 32 个跳步分为两组，分别乘以两个不同的大质数 `u` 和 `v`：

```cpp
// u: 2^(jumpBit/2) 附近的最小奇质数
u.SetInt32(1); u.ShiftL(jumpBit/2); u.AddOne();
while(!u.IsProbablePrime()) { u.AddOne(); u.AddOne(); }

// v: u 之后的下一个奇质数
v.Set(&u); v.AddOne(); v.AddOne();
while(!v.IsProbablePrime()) { v.AddOne(); v.AddOne(); }

// 前 16 步：随机数 * u
for(int i = 0; i < NB_JUMP/2; ++i) {
  jumpDistance[i].Rand(jumpBit/2);
  jumpDistance[i].Mult(&u);
}
// 后 16 步：随机数 * v
for(int i = NB_JUMP/2; i < NB_JUMP; ++i) {
  jumpDistance[i].Rand(jumpBit/2);
  jumpDistance[i].Mult(&v);
}
```

> **设计意图**：利用不同质数乘子将两个对称等价类（symClass=0/1）的跳跃步长结构性分离，避免跨类碰撞。

### 2.4 袋鼠群初始化

来源：[`Kangaroo.cpp:815-883`](Kangaroo.cpp)

```
非对称模式：
  Tame 初始距离 d ∈ [0, 2^rangePower)
  Wild 初始距离 d ∈ [-N/2, N/2)    （N = rangeWidth）

对称优化模式（USE_SYMMETRY）：
  Tame 初始距离 d ∈ [0, 2^(rangePower-1))
  Wild 初始距离 d ∈ [-N/4, N/4)
```

初始椭圆曲线位置：
- Tame：`P_tame = d * G`
- Wild：`P_wild = P_target + d * G`（P_target 已相对中点偏移）

### 2.5 碰撞检测与私钥还原

来源：[`Kangaroo.cpp:252-367`](Kangaroo.cpp)

```cpp
// CheckKey: 枚举 4 种符号组合验证候选私钥
bool Kangaroo::CheckKey(Int d1, Int d2, uint8_t type) {
  if(type & 0x1) d1.ModNegK1order();   // 可选取反 d1
  if(type & 0x2) d2.ModNegK1order();   // 可选取反 d2

  Int pk(&d1);
  pk.ModAddK1order(&d2);               // pk = d1 + d2

  Point P = secp->ComputePublicKey(&pk);
  // 验证 pk*G == keyToSearch（移位后的目标）
  // ...
}

// CollisionCheck: 排除同类碰撞，尝试 4 种等价关系
bool Kangaroo::CollisionCheck(Int* d1, uint32_t type1, Int* d2, uint32_t type2) {
  if(type1 == type2) return false;     // 同类（Tame-Tame 或 Wild-Wild）忽略

  // 提取 Tame 和 Wild 距离
  Int Td, Wd;
  if(type1 == TAME) { Td.Set(d1); Wd.Set(d2); }
  else              { Td.Set(d2); Wd.Set(d1); }

  // 尝试 type=0,1,2,3 四种符号组合
  endOfSearch = CheckKey(Td,Wd,0) || CheckKey(Td,Wd,1)
             || CheckKey(Td,Wd,2) || CheckKey(Td,Wd,3);
  return endOfSearch;
}
```

### 2.6 预期计算复杂度

来源：[`Kangaroo.cpp:981-1017`](Kangaroo.cpp)

$$E[\text{ops}] \approx 2(2 - \sqrt{2})\sqrt{\pi} \cdot \left( \sqrt{N} + \frac{k \cdot 2^{dpSize}}{2} \right)$$

其中 $N = 2^{rangePower}$，$k$ 为袋鼠总数。开启 `USE_SYMMETRY` 时有效范围缩小为 $N/\sqrt{2}$，加速约 $\sqrt{2}$ 倍。

Puzzle 135 示例（`rangePower=135`，`k≈2^26`，`dpSize=43`）预期约 $2^{67\sim68}$ 次操作。

---

## 3. 核心数据结构

### 3.1 192 位有符号距离编码

来源：[`HashTable.h:47-55`](HashTable.h)

```cpp
// 192-bit distance: i64[2] bit63=sign, i64[2] bit62=kType, bits189..0=magnitude
union int192_s {
  uint32_t i32[6];
  uint64_t i64[3];
};
typedef union int192_s int192_t;
```

**位字段分配**：

| 字段 | 位置 | 含义 |
|------|------|------|
| 符号位（sign） | `i64[2]` bit 63 | 0=正距离，1=负距离 |
| 类型位（kType）| `i64[2]` bit 62 | 0=Tame，1=Wild |
| 量级高位 | `i64[2]` bits 61-0 | 距离量级的高 62 位 |
| 量级低位 | `i64[1]`, `i64[0]` | 距离量级的低 128 位 |

**有效位数**：190 位量级（支持最大 $2^{190}$ 的距离）。

### 3.2 ENTRY 结构（哈希表条目）

来源：[`HashTable.h:61-66`](HashTable.h)

```cpp
typedef struct {
  int128_t  x;    // 袋鼠当前 X 坐标（取低 128 位 LSB）
  int192_t  d;    // 已行走距离（含符号和类型，共 192 位）
} ENTRY;          // sizeof(ENTRY) = 16 + 24 = 40 字节
```

> **注意**：仅存储 X 坐标的低 128 位（16 字节）。发生两个 128 位碰撞误判的概率约为 $2^{-73}$，对实际使用可忽略。

### 3.3 HashTable（哈希表）

来源：[`HashTable.h:68-120`](HashTable.h)

```cpp
#define HASH_SIZE_BIT 18
#define HASH_SIZE (1 << 18)   // 262144 个桶
#define HASH_MASK (HASH_SIZE - 1)

typedef struct {
  uint32_t   nbItem;    // 当前桶内条目数
  uint32_t   maxItem;   // 已分配的最大条目数
  ENTRY    **items;     // 二级指针数组（有序，支持二分查找）
} HASH_ENTRY;

class HashTable {
  HASH_ENTRY E[HASH_SIZE];  // 静态桶数组
  // 碰撞信息（供 CollisionCheck 使用）
  Int      kDist;
  uint32_t kType;
  int128_t kXExisting, kXIncoming;
  int192_t kDExisting, kDIncoming;
  // ...
};
```

**桶索引计算**：`h = x.bits64[2] & HASH_MASK`（取 X 坐标的第三个 64 位字的低 18 位）。

**碰撞检测**：`Add()` 方法在插入时按 `int128_t x` 二分查找，若同 X 坐标已存在不同类型的条目（一个 Tame 一个 Wild），则返回 `ADD_COLLISION`，触发 `CollisionCheck`。

### 3.4 TH_PARAM（线程参数结构）

来源：[`Kangaroo.h:59-91`](Kangaroo.h)

```cpp
typedef struct {
  Kangaroo *obj;
  int       threadId;
  bool      isRunning, hasStarted, isWaiting;
  uint64_t  nbKangaroo;         // 本线程持有的袋鼠数量

  Int      *px, *py;            // 袋鼠当前坐标数组
  Int      *distance;           // 已行走距离数组
#ifdef USE_SYMMETRY
  uint64_t *symClass;           // 对称等价类状态（0 或 1）
#endif

  // GPU 专属
  int       gridSizeX, gridSizeY, gpuId;
  // 网络模式专属
  SOCKET    clientSock;
  uint32_t  hStart, hStop;      // 负责的哈希桶范围（分布式）
} TH_PARAM;
```

---

## 4. CPU 底层实现——大整数与模运算

### 4.1 Int 大整数表示

来源：[`SECPK1/Int.h:40-50`](SECPK1/Int.h)

```cpp
#define BISIZE 256
#define NB64BLOCK 5      // 5 × 64 = 320 位（256 位 + 64 位溢出）
#define NB32BLOCK 10

class Int {
public:
  union {
    uint32_t bits[NB32BLOCK];     // 32 位视图
    uint64_t bits64[NB64BLOCK];   // 64 位视图（主要使用）
  };
  // ...
};
```

> `bits64[4]`（第5个 64 位块）用于存放运算中的溢出进位，不参与最终结果。`bits64[3]` 是有效值的最高位。

### 4.2 平台特定指令

来源：[`SECPK1/Int.h:213-310`](SECPK1/Int.h)

#### ARM64（Apple Silicon）

```cpp
// 64×64 → 128 位无符号乘法（用 __uint128_t 模拟）
static uint64_t inline _umul128(uint64_t a, uint64_t b, uint64_t *h) {
  __uint128_t r = (__uint128_t)a * b;
  *h = (uint64_t)(r >> 64);
  return (uint64_t)r;
}

// 带进位加法（用 __uint128_t 模拟进位标志）
static unsigned char inline _addcarry_u64(
    unsigned char c_in, uint64_t a, uint64_t b, uint64_t *result) {
  __uint128_t sum = (__uint128_t)a + b + c_in;
  *result = (uint64_t)sum;
  return (unsigned char)(sum >> 64);
}

// 带借位减法
static unsigned char inline _subborrow_u64(
    unsigned char b_in, uint64_t a, uint64_t b, uint64_t *result) {
  __uint128_t sub = (__uint128_t)a - b - b_in;
  *result = (uint64_t)sub;
  return (unsigned char)(sub >> 127);
}

// 高精度性能计时器（系统寄存器）
static uint64_t inline __rdtsc() {
  uint64_t val;
  asm volatile("mrs %0, cntvct_el0" : "=r"(val));
  return val;
}
```

#### x86-64

```cpp
// mulq 指令：rdx:rax = rax × operand
static uint64_t inline _umul128(uint64_t a, uint64_t b, uint64_t *h) {
  uint64_t rhi, rlo;
  __asm__("mulq %[b];" : "=d"(rhi), "=a"(rlo) : "1"(a), [b]"rm"(b));
  *h = rhi;
  return rlo;
}

// 内置进位/借位（编译器生成 ADC/SBB 指令）
#define _addcarry_u64(a,b,c,d) \
  __builtin_ia32_addcarryx_u64(a, b, c, (long long unsigned int*)d)
#define _subborrow_u64(a,b,c,d) \
  __builtin_ia32_sbb_u64(a, b, c, (long long unsigned int*)d)
```

### 4.3 模逆元：DivStep62

来源：[`SECPK1/IntMod.cpp:131-225`](SECPK1/IntMod.cpp)

基于 Thomas Pornin 的 `bingcd` 变体，是当前最快的软件模逆元算法之一。

**核心思路**：将扩展 Euclidean 算法改写为矩阵递推形式，每次迭代处理 62 位：

```
DivStep62(u, v, eta, pos, &uu, &uv, &vu, &vv)
  → 输出 2×2 整数矩阵 [uu uv; vu vv]，满足：
    [u']   [uu  uv] [u]
    [v'] = [vu  vv] [v]  且 u',v' 都右移了 62 位
```

**性能**：平均 ~6.13 轮完成完整 256 位模逆元，约 780K inv/s（在 i5-8500 上）。

**ARM64 移植**：用两个 `int64_t` 变量替代 x86 原版的 `__m128i` 向量操作，避免依赖 SSE/AVX 指令集。

### 4.4 批量逆元：IntGroup

来源：[`SECPK1/IntGroup.h`](SECPK1/IntGroup.h)

CPU 端每批处理 `CPU_GRP_SIZE=1024` 个袋鼠，使用前缀乘积法将 1024 次逆元压缩为 1 次：

```
设：vals = [v0, v1, ..., v1023]
前缀积：prefix[i] = v0 * v1 * ... * vi
一次 ModInv：inv = prefix[1023]^(-1)
反向展开：vals[i]^(-1) = inv(prefix[last]) * prefix[i-1] * vals[i+1..last]
```

**代价**：`3N` 次 ModMul + 1 次 ModInv（对比朴素方法的 N 次 ModInv，节省 ~97% 的逆元计算）。

### 4.5 CPU 主循环摘要

来源：[`Kangaroo.cpp:387-562`](Kangaroo.cpp)，函数 `SolveKeyCPU`

```
每次循环（CPU_GRP_SIZE=1024 个袋鼠）：
  1. 计算所有 dx[g] = px[g] - jumpPoint[j].x     // 差值（分母）
  2. IntGroup::ModInv()                           // 批量求逆（热点！）
  3. for g in 0..1023:
       s = (py[g] - jumpPoint[j].y) * dx[g]^(-1) // 斜率
       rx = s^2 - px[g] - jumpPoint[j].x         // 新 x
       ry = s*(px[g] - rx) - py[g]               // 新 y
       distance[g] += jumpDistance[j]             // 累加步长
       USE_SYMMETRY: if ry < 0: d = -d, symClass ^= 1
  4. if IsDP(px[g].bits64[3]): AddToTable(px,d,type)
```

---

## 5. CUDA GPU 实现

### 5.1 线程组织

来源：[`GPU/GPUEngine.cu`](GPU/GPUEngine.cu)，[`GPU/GPUMath.h`](GPU/GPUMath.h)

```
Kernel 调用：comp_kangaroos<<<gridDim, blockDim>>>(kangaroos, maxFound, found, dpMask)
  - gridDim  = gridSizeX × gridSizeY
  - blockDim = GPU_GRP_SIZE = 128 线程/块
  - 每线程负责 GPU_GRP_SIZE=128 个袋鼠（内层循环）
  - 每次 Kernel 调用执行 NB_RUN=64 步
  - 总袋鼠数 = gridSizeX × gridSizeY × 128 × 128
```

### 5.2 PTX 汇编宏

来源：[`GPU/GPUMath.h:27-48`](GPU/GPUMath.h)

CUDA 使用 PTX 内联汇编精确控制进位链和高精度乘法：

```cuda
// ——— 256 位加法进位链（3 条指令）———
#define UADDO(c,a,b) asm volatile("add.cc.u64 %0,%1,%2;":"=l"(c):"l"(a),"l"(b):"memory")
// add.cc：执行加法，结果写入 c，同时设置进位标志 CC
#define UADDC(c,a,b) asm volatile("addc.cc.u64 %0,%1,%2;":"=l"(c):"l"(a),"l"(b):"memory")
// addc.cc：带 CC 进位加，结果写入 c，更新 CC
#define UADD(c,a,b)  asm volatile("addc.u64 %0,%1,%2;":"=l"(c):"l"(a),"l"(b))
// addc：带 CC 进位加，最后一步（不再更新 CC）

// ——— 256 位减法借位链（对称）———
#define USUBO(c,a,b) asm volatile("sub.cc.u64 %0,%1,%2;":"=l"(c):"l"(a),"l"(b):"memory")
#define USUBC(c,a,b) asm volatile("subc.cc.u64 %0,%1,%2;":"=l"(c):"l"(a),"l"(b):"memory")
#define USUB(c,a,b)  asm volatile("subc.u64 %0,%1,%2;":"=l"(c):"l"(a),"l"(b))

// ——— 64×64 高精度乘法 ———
#define UMULLO(lo,a,b) asm volatile("mul.lo.u64 %0,%1,%2;":"=l"(lo):"l"(a),"l"(b))
// 64×64→低 64 位
#define UMULHI(hi,a,b) asm volatile("mul.hi.u64 %0,%1,%2;":"=l"(hi):"l"(a),"l"(b))
// 64×64→高 64 位

// ——— 乘-加链（用于模乘 512→256 约化）———
#define MADDO(r,a,b,c) asm volatile("mad.hi.cc.u64 %0,%1,%2,%3;":"=l"(r):"l"(a),"l"(b),"l"(c):"memory")
// mad.hi.cc：(a*b >> 64) + c，设置 CC（第一步）
#define MADDC(r,a,b,c) asm volatile("madc.hi.cc.u64 %0,%1,%2,%3;":"=l"(r):"l"(a),"l"(b),"l"(c):"memory")
// madc.hi.cc：带 CC 版，设置 CC（中间步）
#define MADD(r,a,b,c)  asm volatile("madc.hi.u64 %0,%1,%2,%3;":"=l"(r):"l"(a),"l"(b),"l"(c))
// madc.hi：带 CC 版，最后一步
```

**256 位模乘流程（512→256 约化）**：

1. 4 轮 `UMULLO`/`UMULHI` 得到 512 位中间乘积 `r512[0..7]`
2. 取高 256 位 `r512[4..7]`，乘以 secp256k1 约化常数 `kReduceC = 2^32 + 977`（`MADDO/MADDC/MADD`）
3. 结果加回低 256 位完成约化

### 5.3 袋鼠内存布局（合并访问优化）

来源：[`GPU/GPUMath.h:196-311`](GPU/GPUMath.h)

```
布局：Stride 格式（相邻线程访问相邻内存，实现合并全局内存访问）

地址 = blockBase + field_offset * blockDim.x + threadIdx.x

每只袋鼠（USE_SYMMETRY）：12 × uint64 = KSIZE = 12
  field 0-3:  px[0..3]     (X 坐标, 4 × uint64 = 256 位)
  field 4-7:  py[0..3]     (Y 坐标, 4 × uint64 = 256 位)
  field 8-10: d[0..2]      (距离,   3 × uint64 = 192 位)
  field 11:   symClass     (对称类, 1 × uint64)
```

### 5.4 192 位有符号距离操作

来源：[`GPU/GPUMath.h`](GPU/GPUMath.h)

**符号量级加法** `DistAddSigned192`：

```cpp
__device__ __forceinline__ void DistAddSigned192(uint64_t *r, const uint64_t *a) {
  uint64_t sign = r[2] & DIST_SIGN_BIT;        // 提取符号
  uint64_t type = r[2] & DIST_TYPE_BIT;        // 提取类型
  // 分离量级
  uint64_t mag0 = r[0], mag1 = r[1];
  uint64_t mag2 = r[2] & ~(DIST_SIGN_BIT | DIST_TYPE_BIT);

  if(sign == 0ULL) {
    // 正距离：|d| += jump（3 步进位链）
    // ...
  } else {
    // 负距离：|d| -= jump
    if(|d| >= jump) {
      // 保持符号，|d| -= jump
    } else {
      // 翻转符号，result = jump - |d|
    }
  }
  if((mag0|mag1|mag2) == 0) sign = 0;  // 规范化 -0 → +0
  r[2] = mag2 | sign | type;
}
```

**符号翻转** `DistToggleSign192`：仅翻转 bit63（`r[2] ^= DIST_SIGN_BIT`），同时规范化零值。

### 5.5 DP 输出格式

来源：[`GPU/GPUMath.h:174-191`](GPU/GPUMath.h)

```
每条 DP 记录（ITEM_SIZE32=16，共 64 字节）：
  uint32_t[0]:    kIdx 低 32 位
  uint32_t[1-8]:  x 坐标（256 位，8 × uint32）
  uint32_t[9-14]: d 距离（192 位，6 × uint32）
  uint32_t[15]:   kIdx 高 32 位
```

---

## 6. Metal GPU 实现（Apple Silicon）

### 6.1 Metal 封装层与 Kernel 变体

来源：[`GPU/GPUEngineMetal.mm`](GPU/GPUEngineMetal.mm)

`MetalContext` 封装 `MTLDevice`、`MTLCommandQueue`、`MTLComputePipelineState`，通过环境变量 `KANGAROO_METAL_STATE_CACHE_MODE` 选择 Kernel 变体：

| 模式值 | Kernel 函数名 | 内部名称 | 说明 |
|--------|--------------|---------|------|
| 0（默认）| `kangaroo_step` | `"full"` | 全状态缓存在 thread 寄存器，循环内无设备内存读写，最快 |
| 1 | `kangaroo_step_nocache` | `"none"` | 每轮读全状态，适合内存受限场景 |
| 2 | `kangaroo_step_nocache_pxcache` | `"px"` | 仅缓存 px |
| 3 | `kangaroo_step_nocache_dcache` | `"d"` | 仅缓存 d |
| 4 | `kangaroo_step_jacobian_mixed` | `"jacobian"` | Jacobian 混合坐标（实验）|
| 5 | `kangaroo_step_simd_inv` | `"simd"` | SIMD 协作逆元（实验）|

### 6.2 进位链实现（Metal 无 PTX）

来源：[`GPU/KangarooMetal.metal:103-116`](GPU/KangarooMetal.metal)

Metal Shading Language 没有内联汇编，通过 C 语言风格逻辑模拟进位：

```metal
inline ulong addcarry_u64(ulong a, ulong b, thread ulong &carry) {
  ulong sum = a + b;
  ulong out = sum + carry;
  // 进位：原始和溢出 或 累加后溢出
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
```

### 6.3 256 位模乘：32 位分解法

来源：[`GPU/KangarooMetal.metal:119-151`](GPU/KangarooMetal.metal)

Metal 提供 `mulhi(a,b)` 内置函数，但在 Apple M4 Max 上存在性能回归（通过 `KANGAROO_METAL_USE_NATIVE_WIDE_MUL=0/1` 宏切换）。默认采用 32 位分解方案：

```metal
// 64×64 → 128 位乘法（portable 方案）
// a = a1:a0（高低 32 位），b = b1:b0
// 计算 4 个 32 位部分积后组合
inline ulong2 mul64_128(ulong a, ulong b) {
  uint a0 = (uint)(a), a1 = (uint)(a >> 32);
  uint b0 = (uint)(b), b1 = (uint)(b >> 32);
  ulong p00 = (ulong)a0 * b0;   // 最低项
  ulong p01 = (ulong)a0 * b1;   // 交叉项
  ulong p10 = (ulong)a1 * b0;   // 交叉项
  ulong p11 = (ulong)a1 * b1;   // 最高项

  ulong mid = (p00 >> 32) + (p01 & 0xFFFFFFFF) + (p10 & 0xFFFFFFFF);
  ulong lo  = (p00 & 0xFFFFFFFF) | (mid << 32);
  ulong hi  = p11 + (p01 >> 32) + (p10 >> 32) + (mid >> 32);
  return ulong2(lo, hi);
}
```

**512→256 约化**：取高 256 位乘以 secp256k1 Koblitz 约化常数 `kReduceC = 0x1000003D1`（即 $2^{32} + 977$），加回低 256 位完成模约化。

### 6.4 模逆元：Fermat 小定理加法链

来源：[`GPU/KangarooMetal.metal:1048-1141`](GPU/KangarooMetal.metal)

GPU 上不适合使用条件分支密集的 DivStep 算法，改用费马小定理（固定时间）：

$$a^{-1} \equiv a^{p-2} \pmod{p}$$

使用 secp256k1 曲线特化的加法链（Peter Dettman 设计），利用 $p = 2^{256} - 2^{32} - 977$ 的特殊结构：

- 约 250 次 ModSquare + 15 次 ModMul（固定步数，无分支）
- 比通用方法节省约 30-40% 运算量

**选择开关**：`kInvMode=1`（编译时宏，默认启用 Fermat 路径）。

### 6.5 分组逆元（前缀乘积法）

来源：[`GPU/KangarooMetal.metal:1152-1235`](GPU/KangarooMetal.metal)

与 CPU 端 IntGroup 对应，Metal 端也使用前缀乘积法：

```metal
// 1. 前向：计算前缀积 prefix[i] = v[0]*v[1]*...*v[i]
//    特殊处理 v[i]=0（零值标记 zeroMask）
mod_inv_grouped_prefix_zero_safe(dxInv, prefix, zeroMask, kGpuGroupSize);

// 2. 一次 Fermat 逆元
mod_inv_fermat(inv, prefix[kGpuGroupSize-1]);

// 3. 反向：展开各逆元
//    dxInv[i] = inv(prefix[last]) * prefix[i-1]
mod_inv_grouped_scatter_zero_safe(dxInv, prefix, zeroMask, inv, kGpuGroupSize);
```

代价：`3 × kGpuGroupSize` 次 ModMul + 1 次 Fermat 逆元。

### 6.6 仿射坐标椭圆曲线点加法（热路径）

来源：[`GPU/KangarooMetal.metal:1389-1433`](GPU/KangarooMetal.metal)，函数 `point_add_affine_tg`

```metal
// 点加：(px, py) + (jx, jy) = (rx, ry)
// jx, jy 从 threadgroup 共享内存读取（已预加载）
// dxInv = (jx - px)^(-1)（预先通过分组逆元计算）

mod_sub_256_tg(t, y, jy);        // t = py - jy
mod_mul_k1(s, t, dxInv);         // s = (py - jy) / (px - jx)
mod_sqr_k1(t, s);                // t = s²
mod_sub_256_tg(t, t, jx);        // t = s² - jx
mod_sub_256(rx, t, x);           // rx = s² - jx - px
mod_sub_256(t, x, rx);           // t = px - rx
mod_mul_k1(ry, t, s);            // ry = s * (px - rx)
mod_sub_256(ry, ry, y);          // ry = s*(px-rx) - py
```

### 6.7 Kernel 主循环结构

来源：[`GPU/KangarooMetal.metal:1511-1650`](GPU/KangarooMetal.metal)，默认 Kernel `kangaroo_step`

```metal
kernel void kangaroo_step(device ulong *kangaroos    [[buffer(0)]],
                           device uint  *outWords     [[buffer(1)]],
                           constant ulong2 *jumpD    [[buffer(2)]],
                           constant ulong4 *jumpX    [[buffer(3)]],
                           constant ulong4 *jumpY    [[buffer(4)]],
                           constant KernelParams &params [[buffer(5)]],
                           ...,
                           uint localTid [[thread_position_in_threadgroup]],
                           uint groupId  [[threadgroup_position_in_grid]]) {

  // ① 跳跃点预加载到 threadgroup 共享内存（仅前 kNbJump 个线程执行）
  threadgroup ulong tgJumpD[kNbJump][2];
  threadgroup ulong tgJumpX[kNbJump][4];
  threadgroup ulong tgJumpY[kNbJump][4];
  if(localTid < kNbJump) {
    tgJumpD[localTid][0..1] = jumpD[localTid].xy;
    tgJumpX[localTid][0..3] = jumpX[localTid].xyzw;
    tgJumpY[localTid][0..3] = jumpY[localTid].xyzw;
  }
  threadgroup_barrier(mem_flags::mem_threadgroup);  // 同步

  // ② 从设备内存加载本线程负责的 kGpuGroupSize 个袋鼠状态到寄存器
  thread ulong pxCache[kGpuGroupSize][4];   // 寄存器级缓存
  thread ulong pyCache[kGpuGroupSize][4];
  thread ulong dCache[kGpuGroupSize][3];    // 192 位距离
  // ...（加载循环省略）

  // ③ 主迭代循环（kNbRun 步）
  for(uint run = 0; run < kNbRun; run++) {

    // 计算所有 dx[g] = px[g] - jumpPoint[j].x（分母）
    for(uint g = 0; g < kGpuGroupSize; g++) {
      uint j = jump_index_sym(pxCache[g][0], symClassCache[g]);  // 选跳步
      mod_sub_256_tg(dxInv[g], pxCache[g], tgJumpX[j]);
    }

    // 分组逆元
    mod_inv_grouped(dxInv, prefix, zeroMask, kGpuGroupSize);

    // 点加法 + 距离更新 + DP 检测
    for(uint g = 0; g < kGpuGroupSize; g++) {
      // ... 仿射点加（见 6.6）
      dist_add_signed_192(dCache[g][0], dCache[g][1], dCache[g][2],
                          tgJumpD[j][0], tgJumpD[j][1]);
      // USE_SYMMETRY: Y 为负时翻转
      if(dist_toggle_check_y(pyCache[g])) {
        dist_toggle_sign_192(dCache[g][0], dCache[g][1], dCache[g][2]);
        symClassCache[g] ^= 1u;
      }

      // DP 检测：X 坐标最高 64 位前 dpSize 位全为 0
      if((pxCache[g][3] & params.dpMask) == 0ull) {
        uint pos = atomic_add(counter, 1);  // 原子递增输出指针
        if(pos < maxFound) { /* 写入 outWords */ }
      }
    }
  }

  // ④ 状态写回设备内存
  // ...
}
```

**关键设计点**：
- 跳跃点数据（`jumpD/X/Y`）通过 threadgroup 共享内存广播，避免每线程重复读取全局内存
- 袋鼠状态（`pxCache/pyCache/dCache`）全程保留在寄存器中，整个 `kNbRun` 循环不访问设备内存
- DP 命中通过 `atomic_uint` 无锁写入输出缓冲区

### 6.8 192 位有符号距离操作（Metal）

来源：[`GPU/KangarooMetal.metal:790-847`](GPU/KangarooMetal.metal)

```metal
constant ulong kDistSignBit = (1ull << 63);   // 符号位掩码
constant ulong kDistTypeBit = (1ull << 62);   // 类型位掩码

// 有符号加法（sign-magnitude 格式）
inline void dist_add_signed_192(thread ulong &d0, thread ulong &d1, thread ulong &d2,
                                  ulong jmp0, ulong jmp1) {
  ulong signBit = d2 & kDistSignBit;
  d2 &= ~kDistSignBit;   // 分离符号和量级

  if(signBit == 0ull) {
    // 正：|d| += jmp
    ulong carry = 0ull;
    d0 = addcarry_u64(d0, jmp0, carry);
    d1 = addcarry_u64(d1, jmp1, carry);
    d2 = addcarry_u64(d2, 0ull, carry);
  } else {
    // 负：|d| -= jmp，若下溢则翻转符号
    bool magGeJump = (d2 > 0ULL) || (d1 > jmp1) || (d1 == jmp1 && d0 >= jmp0);
    if(magGeJump) {
      // 量级仍大，符号不变，|d| -= jmp
      // ...（3 步借位链）
    } else {
      // 量级翻转，result = jmp - |d|，符号变正
      // ...（3 步借位链 + signBit = 0）
    }
  }
  if((d0 | d1 | d2) == 0ull) signBit = 0ull;  // 规范化 -0 → +0
  d2 |= signBit;
}

// 符号翻转
inline void dist_toggle_sign_192(thread ulong &d0, thread ulong &d1, thread ulong &d2) {
  if((d0 | d1 | (d2 & ~kDistSignBit)) == 0ull)
    d2 &= ~kDistSignBit;  // 零值规范化
  else
    d2 ^= kDistSignBit;   // 正常翻转
}
```

---

## 7. 跨平台统一执行框架

### 7.1 主执行流程

来源：[`Kangaroo.cpp:1065-1230`](Kangaroo.cpp)

```
Kangaroo::Run(nbCPUThread, gpuId, gridSize)
  ├── InitRange()            ← 计算 rangePower，校验 192 位限制
  ├── CreateJumpTable()      ← 生成跳步表（使用常量种子 0x600DCAFE）
  ├── for each keyToSearch:
  │     ├── InitSearchKey()  ← 计算偏移后的目标公钥
  │     ├── FetchKangaroos() ← 从文件恢复 or CreateHerd 新建袋鼠群
  │     ├── LaunchThread(_SolveKeyCPU)  × nbCPUThread
  │     ├── LaunchThread(_SolveKeyGPU)  × nbGPUThread
  │     ├── Process()        ← 主监控循环（刷新速率、触发保存、等待结束）
  │     └── JoinThreads()
  └── hashTable.Reset()
```

### 7.2 CPU 线程 vs GPU 线程协作

**CPU 线程**（`_SolveKeyCPU`）：
- 自主持有 `CPU_GRP_SIZE=1024` 个袋鼠，完整执行跳跃+DP检测+哈希表写入
- 通过 `ghMutex` 锁保护哈希表写入

**GPU 线程**（`_SolveKeyGPU`）：
- 持续调用 GPU Kernel，从输出缓冲区批量读取发现的 DP
- 在 CPU 侧通过 `ghMutex` 将 DP 写入共享哈希表
- `endOfSearch` 原子标志用于所有线程停止条件

### 7.3 速率统计显示

来源：[`Thread.cpp:237-368`](Thread.cpp)

```cpp
uint64_t counters[256];
// counters[0..nbCPUThread-1]：CPU 各线程计数
// counters[0x80+i]：GPU 各设备计数

// 8 点滑动平均（FILTER_SIZE=8），每 2 秒更新
double lastkeyRate[8];
// 显示格式：
// [CPU 5.23 MK/s][GPU 1234.56 MK/s][Count 2^43.21][Dead 0][01:23:45 (Avg 02:00:00)]
```

**计数递增**：
- CPU：`counters[thId] += CPU_GRP_SIZE`（每批 1024 个袋鼠完成后）
- GPU：`counters[0x80+i] += nbThread × groupSize × runCount`

### 7.4 互斥与同步机制

```
ghMutex（pthread_mutex / WIN32 HANDLE）：
  - 保护 hashTable 的所有写操作
  - 所有 CPU 和 GPU 线程在写 DP 时加锁

saveMutex：
  - 协调工作文件保存（避免保存期间数据不一致）
  - 所有线程设置 isWaiting=true 后，主线程才开始保存

endOfSearch（bool，非原子）：
  - 碰撞找到后由 CollisionCheck 设置
  - 所有线程检测到后退出主循环
```

---

## 8. 工作文件格式与持久化

### 8.1 文件类型魔数

来源：[`Kangaroo.h:121-123`](Kangaroo.h)

```cpp
#define HEADW  0xFA6A8001   // 全量工作文件（DP 哈希表 + 可选袋鼠状态）
#define HEADK  0xFA6A8002   // 仅袋鼠状态
#define HEADKS 0xFA6A8003   // 压缩袋鼠状态
```

### 8.2 版本演进

来源：[`Backup.cpp:200-221`](Backup.cpp)

```cpp
loadedWorkHasSymClass = (loadedWorkVersion >= 1);
// v0：128 位距离，无 symClass（历史遗留，已废弃）
// v1：128 位距离，有 symClass 字段
// v2：192 位距离（USE_SYMMETRY 路径的当前格式）

// 兼容性检查（USE_SYMMETRY 编译时）：
if(loadedWorkVersion < 2) {
  printf("LoadWork: ERROR - workfile version %d uses 128-bit distance"
         "(incompatible with 192-bit format).\n", loadedWorkVersion);
  exit(1);  // 强制退出，不允许静默兼容
}
```

### 8.3 HEADW 全量工作文件布局

来源：[`Backup.cpp:149-237`](Backup.cpp)

```
文件结构（二进制，小端序）：

[字节 0-3  ] uint32_t header   = 0xFA6A8001
[字节 4-7  ] uint32_t version  = 2（USE_SYMMETRY）
[字节 8-11 ] uint32_t dpSize
[字节 12-43] uint64_t[4] rangeStart  (256 位，仅低 32 字节有效)
[字节 44-75] uint64_t[4] rangeEnd    (256 位)
[字节 76-107] uint64_t[4] key.x      (256 位)
[字节 108-139] uint64_t[4] key.y     (256 位)
[字节 140-147] uint64_t offsetCount  (已完成操作计数)
[字节 148-155] double   offsetTime   (已用时间，秒)

[哈希表数据]（HASH_SIZE=262144 个桶）
  对每个桶 h = 0..HASH_SIZE-1：
    uint32_t nbItem
    uint32_t maxItem
    对每个条目 i = 0..nbItem-1：
      int128_t x  (16 字节，X 坐标低 128 位)
      int192_t d  (24 字节，192 位有符号距离)

[uint64_t nbLoadedWalk]   (保存的袋鼠数量，0 表示无)
对每只袋鼠 n = 0..nbLoadedWalk-1：
  uint64_t[4] x  (32 字节，X 坐标)
  uint64_t[4] y  (32 字节，Y 坐标)
  uint64_t[4] d  (32 字节，距离)
  uint64_t symClass (8 字节，对称类状态，仅 bit 0 有效)
```

### 8.4 FetchWalks：断点恢复逻辑

来源：[`Backup.cpp:241-273`](Backup.cpp)

```cpp
void Kangaroo::FetchWalks(uint64_t nbWalk, Int *x, Int *y, Int *d, uint64_t *symClass) {
  // 从文件读取已保存的袋鼠（最多 nbWalk 只）
  for(n = 0; n < nbWalk && nbLoadedWalk > 0; n++) {
    fread(&x[n].bits64, 32, 1, fRead);   // X 坐标
    fread(&y[n].bits64, 32, 1, fRead);   // Y 坐标
    fread(&d[n].bits64, 32, 1, fRead);   // 距离
    if(loadedWorkHasSymClass) {
      uint64_t sc = 0;
      fread(&sc, sizeof(uint64_t), 1, fRead);
      if(symClass) symClass[n] = sc & 1ULL;
    }
    nbLoadedWalk--;
  }
  // 不足 nbWalk 时，用 CreateHerd 补充新袋鼠
  if(n < nbWalk)
    CreateHerd((int)(nbWalk - n), &x[n], &y[n], &d[n], TAME);
}
```

---

## 9. 对称优化（USE_SYMMETRY）详解

### 9.1 数学原理

secp256k1 上的点满足：若 $(x, y)$ 在曲线上，则 $(x, -y \mod p)$ 也在曲线上，且对应私钥为 $(-k \mod \text{order})$。

通过将所有点的 Y 坐标归一化为"正"（`y < p/2`），可以将搜索空间折半，理论加速约 $\sqrt{2}$ 倍。

### 9.2 搜索区间移位与折叠

来源：[`Kangaroo.cpp:1044-1061`](Kangaroo.cpp)

```cpp
// 以搜索范围中点为原点，折叠到半宽区间
SP = rangeStart + rangeWidth / 2;
keyToSearch = keysToSearch[keyIdx] - SP * G;  // 移位目标公钥

// 袋鼠初始距离（相对偏移中点）：
// Tame: d ∈ [0, N/2)    (N = rangeWidth)
// Wild: d ∈ [-N/4, N/4)
```

### 9.3 symClass 机制（CPU 端）

来源：[`Kangaroo.cpp:436-487`](Kangaroo.cpp)

每只袋鼠维护一个 `symClass`（0 或 1），记录当前的对称等价类状态：

```cpp
// 每步跳跃后，检查 Y 坐标是否为负：
if(ry.ModPositiveK1()) {
  // Y 为负（ry > p/2）时：
  // 1. 翻转 Y：ry = p - ry
  // 2. 翻转距离符号：d = -d (mod order)
  // 3. 切换对称类：symClass ^= 1
  ph->distance[g].ModNegK1order();
  ph->symClass[g] = !ph->symClass[g];
}
```

**`ModPositiveK1` 实现**（`SECPK1/IntMod.cpp`）：
- 若 `this > p/2`（即 Y 为负），则执行 `this = p - this`（取 secp256k1 场的正规化）
- 返回 1 表示发生了翻转，0 表示未翻转

### 9.4 跳步分组与 symClass 关联

对称模式下，前 16 个跳步（乘以 `u`）绑定 `symClass=0`，后 16 个（乘以 `v`）绑定 `symClass=1`：

```
非对称：jmp = px.bits64[0] % 32
对称：  jmp = px.bits64[0] % 16 + 16 * symClass
```

**设计意图**：两组质数乘子结构性地将两个对称类的跳跃步长分开，使得碰撞只发生在同一等价类内，避免跨类混淆。

### 9.5 GPU 端对应实现

**Metal**（`KangarooMetal.metal`）：

```metal
// USE_SYMMETRY 下的跳步索引
uint jump_index_sym(ulong px0, uint symClass) {
  return (uint)(px0 % (kNbJump / 2)) + (kNbJump / 2) * (symClass & 1u);
}

// 每步跳跃后对 Y 坐标的对称处理
if(dist_toggle_check_y(pyCache[g])) {    // Y 大于 p/2？
  dist_toggle_sign_192(...);             // 翻转距离符号
  symClassCache[g] ^= 1u;               // 切换对称类
}
```

### 9.6 碰撞检测的额外偏移

来源：[`Kangaroo.cpp:约 330 行`](Kangaroo.cpp)

对称模式下，碰撞发现后还原私钥时需要额外加上中点偏移：

```
pk_final = pk_recovered + rangeStart + rangeWidth/2
         = (dTame ± dWild) + rangeStart + rangeWidth/2
```

---

## 10. 高位 Puzzle（135 位）支持与限制

### 10.1 为何需要 192 位距离

- 袋鼠最大行走距离约为 $2^{rangePower/2}$
- Puzzle 135 的 `rangePower=135`，距离最大约 $2^{67\sim68}$
- 旧版 128 位距离：128 位有效量级，另需 1 位符号 + 1 位类型 = 仅 126 位量级，不足
- 升级后 192 位距离：190 位有效量级，充裕覆盖 135 位 Puzzle

**升级影响**：
- `ENTRY` 结构从 32 字节增加到 40 字节（+8 字节的 `int192_t` 扩展）
- GPU 每袋鼠内存从 10 × uint64 增加到 12 × uint64（+2 个 uint64：d[2] 和 symClass）
- 工作文件格式升级到 v2

### 10.2 硬性距离限制

来源：[`Kangaroo.cpp:1036-1040`](Kangaroo.cpp)

```cpp
#ifdef USE_SYMMETRY
  if(rangePower - 1 > 190) {
    printf("FATAL: rangePower=%d exceeds 192-bit distance limit (max 191)\n", rangePower);
    exit(1);
  }
#endif
// 最大支持：rangePower=191，即搜索范围宽度 < 2^191
```

### 10.3 Puzzle 135 实际参数参考

以用户命令为例：

```bash
./kangaroo -gpu -gpuId 0 -g 80,256 -d 43 -t 0 \
  -w puzzle135_test.work -wi 120 -ws -wt 15000 \
  -o puzzle135_result.txt puzzle135.txt
```

| 参数 | 值 | 含义 |
|------|----|------|
| `-g 80,256` | gridX=80, gridY=256 | GPU 网格 80×256=20480 线程组 |
| `-d 43` | dpSize=43 | DP 前导零 43 位，约每 $2^{43}$ 步记录一个 DP |
| `-t 0` | 无 CPU 线程 | 全 GPU 模式 |
| `-wi 120` | 120 秒 | 每 2 分钟保存一次工作文件 |
| `-ws` | 启用 | 同时保存袋鼠状态（支持真正断点续跑）|
| `-wt 15000` | 15000 ms | 保存操作最多等待 15 秒 |

**总袋鼠数**：`80 × 256 × 128 × 128 ≈ 336,920,576`（约 $2^{28.3}$）

**预期计算量**：`rangePower=135`，$N \approx 2^{135}$，预期约 $2^{67\sim68}$ 次操作，在高性能 GPU（Apple M 系列 GPU）上需数月至数年持续运行。

### 10.4 工作文件兼容性约束

- v2 格式与旧版（v0/v1）**不兼容**，加载旧文件会强制报错退出
- 不同机器之间的工作文件可以互换（跳步表由常量种子 `0x600DCAFE` 生成，跨机器一致）
- 合并工具（`-wm`/`-wmdir`）支持将多机的工作文件合并，加速碰撞发现

---

## 11. 附录：关键常量速查表

| 常量 | 值 | 含义 | 来源 |
|------|----|------|------|
| `NB_JUMP` | 32 | 跳步表大小（对称时前/后各16个） | `Kangaroo.h` |
| `CPU_GRP_SIZE` | 1024 | CPU 批量逆元组大小 | `Kangaroo.cpp:110` |
| `GPU_GRP_SIZE` | 128 | GPU 每线程负责的袋鼠数 | `GPUEngine.h` |
| `NB_RUN` | 64 | GPU 每次 Kernel 调用的迭代步数 | `GPUEngine.h` |
| `HASH_SIZE_BIT` | 18 | 哈希桶位数 | `HashTable.h:28` |
| `HASH_SIZE` | 262144（2^18）| 哈希桶总数 | `HashTable.h:29` |
| `NB64BLOCK` | 5 | Int 内部 uint64 块数（320 位）| `SECPK1/Int.h` |
| `HEADW` | `0xFA6A8001` | 全量工作文件魔数 | `Kangaroo.h:121` |
| `kP0` | `0xFFFFFFFEFFFFFC2F` | secp256k1 素数 $p$ 最低 64 位 | `KangarooMetal.metal:43` |
| `kReduceC` | `0x1000003D1` | secp256k1 模乘约化常数（$2^{32}+977$）| `KangarooMetal.metal:51` |
| `kOrder0` | `0xBFD25E8CD0364141` | 曲线阶 $n$ 最低 64 位 | `KangarooMetal.metal:48` |
| `kDistSignBit` | `1ull << 63` | 192 位距离符号位掩码 | `KangarooMetal.metal:729` |
| `kDistTypeBit` | `1ull << 62` | 192 位距离类型位掩码 | `KangarooMetal.metal:730` |
| `MM64` | `0xD838091DD2253531` | $p$ 的 64 位负逆元（Montgomery 参数）| `GPU/GPUMath.h:65` |
| Jump 种子 | `0x600DCAFE` | 跳步表随机种子（跨机器兼容）| `Kangaroo.cpp:906` |

---

*文档生成时间：2026-02-25。所有信息通过直接阅读源代码获取，不依赖任何旧版文档。*
