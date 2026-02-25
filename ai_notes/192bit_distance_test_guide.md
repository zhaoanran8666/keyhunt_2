# 192位距离升级验证测试方案

> **用途**：在 keyhunt_2 完成 distance 128→192位升级后，通过构造 >128bit 的极限测试用例，严谨验证大数距离算术（距离累加、碰撞检测、减法恢复私钥）的正确性。
> **验证通过时间**：2026-02-25
> **测试耗时**：约 9 秒（Apple M4 Max Metal GPU）

---

## 一、测试原理

Pollard Kangaroo 算法中，野鼠（Wild）和驯鼠（Tame）各自的"距离"最终相减得到私钥：

```
私钥 k = d_Tame_stored - d_Wild_stored
```

当搜索范围超过 2^128，d_Tame_stored 的值自然会 >128 bit，从而强制触发 192位大数运算。

**构造思路**：

| 参数 | 值 | 说明 |
|------|----|------|
| 搜索范围 | [0, 2^140] | rangePower=141，远超 128bit |
| 目标私钥 | **2^139** | Tame 初始距离 ≈ 2^139，>128bit |
| 跳跃步长 | **2^20**（强制写死） | 原本 ~2^70，压缩后使碰撞在数万步内发生 |
| 出生偏移 | **±2^20** 内（强制写死） | 野鼠和驯鼠都聚集在 2^139·G 附近 |
| DP 掩码 | **-d 5**（1/32 密度） | 每个 kernel round ~3万次 DP 写入，GPU 可承受 |

野鼠 EC 点 = keyToSearch + tiny·G = (2^139 + tiny)·G
驯鼠 EC 点 = (2^139 + tiny)·G
两者聚集于同一区域，数万步内必然碰撞，碰撞时 d_T - d_W = **2^139** ✓

---

## 二、注意事项（坑）

### 1. 不能使用 sym=1 编译

`sym=1` (USE_SYMMETRY) 会在 `InitSearchKey()` 中将目标公钥相对范围中点做调整：

```cpp
// Kangaroo.cpp InitSearchKey() ~line 1050
SP.ModAddK1order(&rangeWidthDiv2);     // SP = 0 + 2^139 = 2^139
Point RS = secp->ComputePublicKey(&SP);
RS.y.ModNeg();
keyToSearch = secp->AddDirect(keysToSearch[keyIdx], RS);
// = 2^139*G + (-(2^139*G)) = O（无穷点！）
```

当搜索目标恰好在范围中点（2^139 = 中点 2^139），`keyToSearch` 退化为无穷点 O。
而 `AddDirect()` **不处理无穷点**，会直接计算斜率（除以 Δx=0），得到错误结果。

**→ 本测试必须用 `gpu=1`，不加 `sym=1`。**

### 2. -d 0 会压垮 GPU 输出缓冲区

dMask=0 时，GPU 的 2.6M 袋鼠每步全部写入 DP 缓冲区 → 溢出。
**→ 使用 `-d 5`**（1/32 密度），以 SetDP(5) 覆盖代码中临时写入的 dMask=0。

---

## 三、操作步骤（完整流程）

### Step 0：计算目标公钥，写入 test140.txt

```bash
# 在 keyhunt_2 根目录执行
conda run -n deeplearning python3 -c "
from ecdsa import SigningKey, SECP256k1
sk = SigningKey.from_string((2**139).to_bytes(32, 'big'), curve=SECP256k1)
vk = sk.get_verifying_key()
x = vk.pubkey.point.x()
y = vk.pubkey.point.y()
print(('02' if y % 2 == 0 else '03') + hex(x)[2:].zfill(64))
"
```

输出（已确认）：`02ee7d69c4cbd001c7fc76c5e2c066ce4996f8808a1e07b2a9ccf34eadc87c4b65`

写入 `test140.txt`（**格式同 puzzle135.txt：第1行起点、第2行终点、第3行公钥**）：

```
0
100000000000000000000000000000000000
02ee7d69c4cbd001c7fc76c5e2c066ce4996f8808a1e07b2a9ccf34eadc87c4b65
```

> `100000000000000000000000000000000000` = 2^140（1 后跟 35 个十六进制零，共 36 字符）

---

### Step 1：修改 Kangaroo.cpp（3 处，加 [TEST192] 注释便于搜索）

**文件路径**：`Kangaroo/Kangaroo.cpp`

#### 改动 A：CreateJumpTable() — 行 ~897，强制 jumpBit = 20

定位：`if(jumpBit > 128) jumpBit = 128;` 这一行之后，插入：

```cpp
  if(jumpBit > 128) jumpBit = 128;
  jumpBit = 20;  // [TEST192] force 2^20 jump size for rapid 192-bit collision test
```

#### 改动 B：CreateJumpTable() — 行 ~974，函数末尾加 dMask=0 兜底

定位：`::printf("Jump Avg distance: 2^%.2f\n",log2(distAvg));` 这一行之后，插入：

```cpp
  ::printf("Jump Avg distance: 2^%.2f\n",log2(distAvg));

  // [TEST192] force dMask=0: every point is a DP, collision detected immediately
  dMask = 0;
  ::printf("[TEST192] dMask=0: all points are distinguished points\n");
```

> 注：运行时 `-d 5` 会让 SetDP(5) 覆盖此处的 dMask=0，但保留这行作为 CPU-only 模式下的保险。

#### 改动 C：CreateHerd() — 行 ~842，#else 分支（非对称模式）

定位并替换整个 `#else` ... `#endif` 内的内容（约行 842-851）：

**原始代码：**
```cpp
#else

    // Tame in [0..N]
    d[j].Rand(rangePower);
    if((j + firstType) % 2 == WILD) {
      // Wild in [-N/2..N/2]
      d[j].ModSubK1order(&rangeWidthDiv2);
    }

#endif
```

**替换为：**
```cpp
#else

    // [TEST192] force 2^20 spread clustered near 2^139·G for 192-bit distance test
    d[j].Rand(20);
    if((j + firstType) % 2 == TAME) {
      // Tame: d = 2^139 + tiny -> EC point = (2^139 + tiny)·G
      d[j].Add(&rangeWidthDiv2);
    }
    // Wild: d = tiny -> EC point = keyToSearch + tiny·G = (2^139 + tiny)·G

#endif
```

验证 3 处标记已写入：
```bash
grep -n "TEST192" Kangaroo/Kangaroo.cpp
# 预期输出 3 行（行 ~835/844/896/975/977）
```

---

### Step 2：编译（gpu=1，不加 sym=1）

```bash
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
make clean && make gpu=1 -j8
```

预期：仅有 deprecation 警告，无错误。

---

### Step 3：运行测试

```bash
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
unset KANGAROO_METAL_STATE_CACHE_MODE KANGAROO_METAL_NO_STATE_CACHE KANGAROO_METAL_DISABLE_AUTO_MODE14

KANGAROO_METAL_AUTO_MODE14_WARMUP=1 \
KANGAROO_METAL_AUTO_MODE14_ITERS=2 \
KANGAROO_METAL_AUTO_MODE14_MIN_GAIN_PCT=0 \
KANGAROO_METAL_BLOCK_WAIT=1 \
KANGAROO_METAL_GRP_SIZE=128 \
KANGAROO_METAL_NB_RUN=2 \
KANGAROO_METAL_WAIT_TIMEOUT_MS=8000 \
./kangaroo -gpu -gpuId 0 -g 80,256 -d 5 -t 0 \
  /Users/zhaoanran/Desktop/keyhunt_2/test140.txt
```

**预期输出（约 9 秒内）：**

```
Range width: 2^141
Jump Avg distance: 2^18.xx
[TEST192] dMask=0: all points are distinguished points
...
Key# 0 [1S]Pub:  0x02EE7D69C4CBD001C7FC76C5E2C066CE4996F8808A1E07B2A9CCF34EADC87C4B65
       Priv: 0x80000000000000000000000000000000000

Done: Total time 0Xs
```

> `Warning, XXXXX items lost` 属正常现象（少量 DP 因缓冲区满被丢弃，不影响结果）。

**验收标准**：`Priv: 0x80000000000000000000000000000000000` = 2^139 ✓

---

### Step 4：还原代码（测试完成后必做）

```bash
cd /Users/zhaoanran/Desktop/keyhunt_2

# 1. 还原 Kangaroo.cpp
git checkout Kangaroo/Kangaroo.cpp

# 2. 删除测试输入文件
rm test140.txt

# 3. 验证干净
grep "TEST192" Kangaroo/Kangaroo.cpp && echo "未完全还原！" || echo "Clean ✓"
git diff Kangaroo/Kangaroo.cpp   # 应为空输出
```

### Step 5：恢复生产编译

```bash
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
make clean && make gpu=1 sym=1 -j8
```

---

## 四、改动速查表

| 函数 | 位置（关键字搜索） | 改动内容 |
|------|-------------------|----------|
| `CreateJumpTable()` | `if(jumpBit > 128) jumpBit = 128;` 之后 | 插入 `jumpBit = 20;` |
| `CreateJumpTable()` | `printf("Jump Avg distance...")` 之后 | 插入 `dMask = 0;` + printf |
| `CreateHerd()` | `#else` 分支内 `d[j].Rand(rangePower);` 块 | 替换为 Rand(20) + TAME 加 rangeWidthDiv2 |

还原只需一条命令：`git checkout Kangaroo/Kangaroo.cpp`

---

## 五、数学验证

```
d_Tame_stored = 2^139 + tame_jump_total        (初始 rangeWidthDiv2 + tiny)
d_Wild_stored = wild_jump_total                 (初始 tiny ≈ 0)

碰撞时（两只袋鼠到达相同 EC 点）：
  d_Tame_stored · G = keyToSearch + d_Wild_stored · G
  d_Tame_stored · G = 2^139·G + d_Wild_stored · G
  (d_Tame_stored - d_Wild_stored) · G = 2^139·G

∴ 私钥 = d_Tame_stored - d_Wild_stored = 2^139     ✓

其中 d_Tame_stored ≈ 2^139 >> 2^128，全程触发 192位大数运算路径
```

---

## 六、测试覆盖的代码路径

| 模块 | 被验证的功能 |
|------|-------------|
| `Kangaroo.cpp` CreateHerd | `Int::Add()` 大数加法（rangeWidthDiv2 = 2^139） |
| `Kangaroo.cpp` SolveKeyGPU | `EncodeGpuDistanceSym` / `DecodeGpuDistanceSym` 192位编解码 |
| `GPU/GPUEngineMetal.mm` SetKangaroos | 192位距离传输（d0/d1/d2 三个 uint64 字段） |
| `KangarooMetal.metal` shader | GPU 端距离累加和 DP 检测 |
| `HashTable.cpp` Add/CalcDist | `int192_t` 存储与 i64[3] 读写 |
| `Kangaroo.cpp` CollisionCheck | `ModSubK1order` 对 >128bit 的 192位减法 |
| `Backup/Network/Check` | 序列化/反序列化 192位距离字段 |
