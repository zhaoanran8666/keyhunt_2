# Kangaroo 文档核验报告（Metal 135# / 断点续跑 / 出钥链路）

> 结论先行：
>
> - 以当前源码实现来看，`Metal` 路径在 `USE_SYMMETRY + 192-bit 距离` 条件下，能够支持你给出的 `135#` 高位 puzzle 场景，并在碰撞命中后通过 CPU 侧统一验钥链路正确输出密钥。
> - `-w/-wi/-ws/-wt` + `-i` 的续跑机制在逻辑上成立，但要区分“可恢复继续搜索”和“严格逐步等价续跑”；当前 GPU（含 Metal）路径存在一个**快照一致性边界**（可能漏掉最近一次 inflight kernel 的 DP 入表），这不影响最终正确性，但会影响“完全精确快照”的定义。
> - `Kangaroo/ALGORITHM_TECH_DOC_CODE_ONLY_PUZZLE135_CN_20260225.md` 整体准确度较高，适合作为当前版本主要技术文档；`Kangaroo/ALGORITHM_TECH_DOC.md` 在 Metal 模式映射、Puzzle135 参数与工作量估算等处存在多处实质性错误，不能作为你当前 Metal 135# 场景的权威说明。

---

## 1. 任务范围与核验方法（代码唯一依据）

本报告严格基于源码核验，未以旧文档内容作为事实依据。

核验范围（与你要求直接相关）：

- `Metal` 设备上的高位 `135#` puzzle 求解链路
- `-w/-wi/-ws/-wt` 保存 + `-i` 恢复续跑链路
- 命中后私钥恢复与输出文件写入链路
- 相关边界情况（配置变化、版本兼容、GPU pipeline 快照一致性）
- 两份文档对上述逻辑的准确性

核心核验代码路径：

- 参数与主控：`Kangaroo/main.cpp`，`Kangaroo/Kangaroo.cpp`，`Kangaroo/Thread.cpp`
- 工作文件：`Kangaroo/Backup.cpp`，`Kangaroo/HashTable.{h,cpp}`
- Metal host/shader：`Kangaroo/GPU/GPUEngineMetal.mm`，`Kangaroo/GPU/KangarooMetal.metal`
- GPU/CPU一致性校验：`Kangaroo/Check.cpp`
- 底层算术/指令：`Kangaroo/SECPK1/Int.h`，`Kangaroo/SECPK1/IntMod.cpp`，`Kangaroo/GPU/GPUMath.h`

---

## 2. 两份文档的总体判断

### 2.1 `ALGORITHM_TECH_DOC_CODE_ONLY_PUZZLE135_CN_20260225.md`

结论：**总体准确，适合作为当前版本主文档**（尤其在 `puzzle135` 位宽语义、Metal 默认 `groupSize=16`、mode4/5 映射、v2 workfile 与 192-bit 距离升级等关键点上）。

主要优点（经代码核对成立）：

- 正确指出 `puzzle135.txt` 对当前实现的 `rangePower` 是 `134`（因为代码使用 `rangeEnd - rangeStart` 的 bitlen）
- 正确指出 Metal 默认 `groupSize=16`（非 CUDA 的 `128`）
- 正确指出 Metal `stateCache` 模式映射：`4=simd`，`5=jacobian`
- 正确指出 `USE_SYMMETRY` 下使用 `int192_t` / `EncodeGpuDistanceSym` / `DecodeGpuDistanceSym`
- 正确指出 `-ws` 对“真正断点续跑”是必要条件
- 正确指出最终正确性由 CPU 侧 `CollisionCheck/CheckKey/Output` 兜底

仍建议补充/修正的点（不是代码错误，是文档精度提升项）：

- 补充说明 GPU（含 Metal）保存快照时的 **“一帧/一launch DP 入表滞后”** 边界（见本报告第 6.4 节）
- 补充说明续跑若修改 `-g` 或 `KANGAROO_METAL_GRP_SIZE`，恢复将变成“部分恢复 + 部分新建”，不是严格等价继续
- 补充说明 `-i` 与 `-d` 同时使用时，命令行 `-d` 会覆盖 workfile 保存的 DP 位数（代码允许）
- 补充说明 Metal `stateCache` 在未显式设置环境变量时，默认运行策略通常是 `auto(1/4)` 或回退到 `1`，不是直接 `0(full)`

### 2.2 `ALGORITHM_TECH_DOC.md`

结论：**不适合作为当前 Metal 135# + 续跑场景的权威文档**。其内容有不少高价值部分，但关键章节存在多处实质性错误/过时表述。

最重要的错误集中在：

- Metal `stateCache` 模式编号与 kernel 映射（写反）
- Puzzle135 的 `rangePower` 与工作量估算（基于错误 `rangePower=135`）
- 你给定命令的总袋鼠数估算（与 Metal 实际参数不符，且公式本身有误）
- Metal 路径中并不存在的 `kDistTypeBit` 常量描述
- workfile 版本语义对当前代码（尤其非对称路径）描述不准确

---

## 3. 文档核验发现（按影响排序）

## 3.1 [高影响] `ALGORITHM_TECH_DOC.md` 将 Metal mode 4 / mode 5 映射写反

文档位置：`Kangaroo/ALGORITHM_TECH_DOC.md:599-607`

文档写法（错误）：

- `4 -> jacobian`
- `5 -> simd`

源码事实：

- `4 -> kangaroo_step_simd_inv`
- `5 -> kangaroo_step_jacobian_mixed`

证据：

- `Kangaroo/GPU/GPUEngineMetal.mm:257-272` (`GetStateCacheKernelName`)
- `Kangaroo/GPU/GPUEngineMetal.mm:274-289` (`GetStateCacheModeName`)

影响：

- 会直接误导对 Metal 性能模式的理解与调参
- 与文档后文“symmetry 下 mode 5 回退 mode 1”的描述组合后，会错误推导成“simd 在 symmetry 下不可用”
- 实际上被禁用的是 **jacobian(mode 5)**，而 **simd(mode 4)** 才是 auto mode14 的目标之一

---

## 3.2 [高影响] `ALGORITHM_TECH_DOC.md` 对 `puzzle135` 的 `rangePower` 写成 135（当前实现下不成立）

文档位置（多处）：

- `Kangaroo/ALGORITHM_TECH_DOC.md:241`
- `Kangaroo/ALGORITHM_TECH_DOC.md:1080`
- `Kangaroo/ALGORITHM_TECH_DOC.md:1124`

源码事实：

- `rangePower = bitlen(rangeEnd - rangeStart)`，不是“候选值位数标签”
- `puzzle135.txt` 当前内容为：
  - `start = 2^134`
  - `end = 2^135 - 1`
- 因此：
  - `rangeWidth = end - start = 2^134 - 1`
  - `rangePower = 134`

证据：

- `Kangaroo/puzzle135.txt:1-3`
- `Kangaroo/Kangaroo.cpp:126-184` (`ParseConfigFile`)
- `Kangaroo/Kangaroo.cpp:1022-1042` (`InitRange`)

影响：

- 会影响文档对 `ComputeExpected()`、建议 `DP`、预计复杂度的解释
- 会误导对 jump 平均步长目标（`CreateJumpTable`）的理解

说明：

- “这是 135 位高位 puzzle”这个说法本身没问题（按区间标签/候选上界位数理解成立）
- 但**当前代码内部用于估算与跳表构造的 `rangePower` 数值是 134**

---

## 3.3 [高影响] `ALGORITHM_TECH_DOC.md` 对你命令的总袋鼠数估算错误，且不符合 Metal 默认参数

文档位置：`Kangaroo/ALGORITHM_TECH_DOC.md:1122`

文档写法（错误）：

- `80 × 256 × 128 × 128 ≈ 336,920,576`

源码事实（Metal 默认环境下）：

- `-g 80,256` 在 GPU 引擎中表示 `nbThreadGroup=80`, `nbThreadPerGroup=256`
- `nbThread = 80 * 256 = 20480`
- Metal 默认 `groupSize = 16`（`KANGAROO_METAL_GRP_SIZE` 未设置时）
- `nbKangaroo = nbThread * groupSize = 20480 * 16 = 327680`

证据：

- `Kangaroo/Kangaroo.cpp:579-581`
- `Kangaroo/GPU/GPUEngineMetal.mm:579-589`
- `Kangaroo/GPU/GPUEngineMetal.mm:1114-1117`

影响：

- 会显著误判总袋鼠数、建议 DP、预期吞吐与资源占用
- 对 Metal 135# 调参尤其误导（你迁移版默认 `groupSize` 和 CUDA 版不同）

补充：

- 即使按 CUDA 默认 `groupSize=128` 理解，正确也应是 `80 * 256 * 128 = 2,621,440`，而不是文档给出的数值

---

## 3.4 [高影响] `ALGORITHM_TECH_DOC.md` 对 Metal 默认 stateCache 行为描述不准确（默认并非直接 mode 0/full）

文档位置：`Kangaroo/ALGORITHM_TECH_DOC.md:599-607`（表格含“0（默认）”）

源码事实：

- 未显式设置状态模式时，构造函数会优先走 `auto mode14`（在 `mode1(none)` 和 `mode4(simd)` 间基准选择）
- 若 auto 不可用或被禁用，且未显式设置模式，则 `stateCacheMode==0` 会被重定向为 `1(none)`
- 因此“默认运行态 = mode0(full)”并不成立

证据：

- `Kangaroo/GPU/GPUEngineMetal.mm:204-250` (`GetStateCacheMode`, env 解析)
- `Kangaroo/GPU/GPUEngineMetal.mm:627-707`（构造函数内模式选择）
- `Kangaroo/GPU/GPUEngineMetal.mm:691-693`（未显式设置时 `0 -> 1`）
- `Kangaroo/GPU/GPUEngineMetal.mm:662-688`（auto mode14 初始化为 mode1）

影响：

- 会误导对实际运行 kernel 的判断
- 在分析性能日志 / 复现实验时容易得出错误结论

---

## 3.5 [中影响] `ALGORITHM_TECH_DOC.md` 在 Metal 192-bit 距离章节引入了并不存在的 `kDistTypeBit` 常量

文档位置：`Kangaroo/ALGORITHM_TECH_DOC.md:791-794`

文档写法（不符合当前代码）：

- 在 `KangarooMetal.metal` 里展示 `kDistTypeBit`

源码事实：

- `KangarooMetal.metal` 中只有 `kDistSignBit`（用于 GPU 内部 sign-magnitude 距离）
- `kType` 在 GPU/Metal DP 输出路径并不存入距离字段，而是由 host 通过 `kIdx % 2` 推导
- `HashTable` 的 type bit 编码发生在 CPU 侧 `HashTable::Convert()`（入表时）

证据：

- `Kangaroo/GPU/KangarooMetal.metal:733`（`kDistSignBit`）
- `Kangaroo/GPU/KangarooMetal.metal:793-847`（`dist_add_signed_192` / `dist_toggle_sign_192`）
- `Kangaroo/Kangaroo.cpp:699-706`（`kType = kIdx % 2` 后入表）
- `Kangaroo/HashTable.cpp:82-109`（`type` 编入 `int192_t` bit62）

影响：

- 容易把“GPU内部距离编码”和“HashTable/网络DP压缩编码”混为一谈

---

## 3.6 [中影响] `ALGORITHM_TECH_DOC.md` 的 workfile 版本语义描述与当前代码不完全一致（尤其非对称路径）

文档位置：`Kangaroo/ALGORITHM_TECH_DOC.md:917-923`

文档写法（过时/不精确）：

- `v1 = 128 位距离，有 symClass`
- `v2 = 192 位距离`

源码事实（当前代码）：

- `SaveHeader()` 在 `USE_SYMMETRY` 下写 `version=2`
- 在非对称路径写 `version=1`，但代码注释明确表示这是“升级后的 192-bit 距离格式标记”（并非旧 128-bit 语义）
- `HashTable::ENTRY` 结构当前统一是 `x(128) + d(192)`，即 `40 bytes`

证据：

- `Kangaroo/Backup.cpp:449-466`
- `Kangaroo/HashTable.h:61-66`

影响：

- 会误导对 workfile 版本兼容的判断，尤其做跨版本工具或离线解析时

说明：

- 对你当前 `Metal + USE_SYMMETRY + 135#` 主要路径，关键结论仍是：**需要 v2**。这点文档是对的。

---

## 4. 代码级确认：Metal 求解 135# 高位 puzzle 的正确性链路

## 4.1 命令与输入文件语义（你给出的命令）

你给的命令（省略换行）解析路径如下：

- 参数解析：`Kangaroo/main.cpp:167-355`
- `-gpu` 启用 GPU，`-gpuId 0` 选第 0 个 Metal 设备（本构建下 `WITHMETAL`）
- `-g 80,256` 作为 `GPUEngine(nbThreadGroup=80, nbThreadPerGroup=256, ...)`
- `-d 43` 设置 DP 位数
- `-t 0` 禁用 CPU 工作线程，仅 GPU 求解线程运行
- `-w/-wi/-ws/-wt` 启用周期保存且保存袋鼠状态
- `-o` 指定结果输出文件（追加写）
- 最后参数 `puzzle135.txt` 走 `ParseConfigFile()`

配置文件格式（当前 `puzzle135.txt`）：

- 第 1 行：起点 `rangeStart`
- 第 2 行：终点 `rangeEnd`
- 第 3 行：目标压缩公钥

证据：

- `Kangaroo/puzzle135.txt:1-3`
- `Kangaroo/Kangaroo.cpp:126-184`

## 4.2 `135#` 场景在当前实现中的关键数值（重要）

源码定义下：

- `rangeWidth = rangeEnd - rangeStart`
- `rangePower = bitlen(rangeWidth)`

因此当前 `puzzle135.txt` 的实际 `rangePower = 134`，不是 135。

证据：

- `Kangaroo/Kangaroo.cpp:1022-1042`

这不会阻止高位 puzzle 求解。它只影响：

- 复杂度估算 `ComputeExpected()`
- `CreateJumpTable()` 的步长目标位数
- 建议 DP 计算

## 4.3 高位支持的本质：距离表示扩展，而非单跳位宽扩展

当前高位支持的关键点是“距离与状态压缩升级到 192-bit”，而不是把单跳距离无限增大。

源码证据：

- `HashTable::ENTRY` 存 `int192_t d`：`Kangaroo/HashTable.h:61-66`
- `HashTable::Convert/CalcDistAndType` 做 192-bit sign/type 编码：`Kangaroo/HashTable.cpp:82-109`, `:258-270`
- 网络 DP 结构也使用 `int192_t d`：`Kangaroo/Kangaroo.h:95-102`
- `USE_SYMMETRY` 下对 `rangePower` 的硬限制是 `rangePower-1 <= 190`：`Kangaroo/Kangaroo.cpp:1035-1040`

对 `135#` 而言，这个上限远未触及。

## 4.4 Metal host/shader 状态与 ABI 一致性（求解正确性的关键）

### A. 状态布局（Kangaroo Buffer）一致

`GPUEngineMetal.mm` 与 `KangarooMetal.metal` 使用一致的 `AoSoA` 布局：

- `x[4]`
- `y[4]`
- `d[3]`
- `symClass`（仅 `USE_SYMMETRY` 时，`KSIZE=12`）

证据：

- `Kangaroo/GPU/GPUEngine.h:25-32`（`KSIZE`）
- `Kangaroo/GPU/GPUEngineMetal.mm:1176-1239`（上传）
- `Kangaroo/GPU/GPUEngineMetal.mm:1380-1449`（回读）
- `Kangaroo/GPU/KangarooMetal.metal:1550-1596`（shader 加载）
- `Kangaroo/GPU/KangarooMetal.metal:1710-1729`（默认核写回）

### B. `KernelParams` 显式 padding 对齐正确

`KernelParams` 两侧都有 `paramPad`，防止 `dpMask` 偏移错位。

证据：

- Host：`Kangaroo/GPU/GPUEngineMetal.mm:53-63`
- Shader：`Kangaroo/GPU/KangarooMetal.metal:53-63`
- 参数赋值：`Kangaroo/GPU/GPUEngineMetal.mm:1557-1567`

### C. DP 输出 ABI 与 host 解码匹配

每条 DP 记录为 `64 bytes`（`ITEM_SIZE32=16` 个 `uint32_t`），字段顺序为：

- `x[4x64]`（8 个 `u32`）
- `d[3x64]`（6 个 `u32`）
- `kIdx`（2 个 `u32`）

证据：

- `Kangaroo/GPU/KangarooMetal.metal:1680-1705`（默认 kernel 输出）
- `Kangaroo/GPU/KangarooMetal.metal:2608-2632`（simd kernel 输出）
- `Kangaroo/GPU/GPUEngine.h:31-32`（`ITEM_SIZE`）
- `Kangaroo/GPU/GPUEngineMetal.mm:1716-1746`（host 解码）
- CUDA 对照：`Kangaroo/GPU/GPUMath.h:174-191`, `Kangaroo/GPU/GPUEngine.cu:771-799`

## 4.5 Metal 对称路径（高位 135# 场景）的关键正确性点

### A. GPU/Metal 距离编码与 CPU 一致性桥接成立

`USE_SYMMETRY` 下，Metal 设备端使用 192-bit sign-magnitude 距离；Host 进出设备时通过：

- `EncodeGpuDistanceSym()`
- `DecodeGpuDistanceSym()`

完成与 CPU `Int`（模阶表示）之间转换。

证据：

- `Kangaroo/GPU/GPUEngine.h:46-84`
- 上传：`Kangaroo/GPU/GPUEngineMetal.mm:1210-1217`
- 回读：`Kangaroo/GPU/GPUEngineMetal.mm:1422-1426`
- DP 解码：`Kangaroo/GPU/GPUEngineMetal.mm:1730-1732`

### B. `symClass` 与跳步半表选择逻辑成立

Metal shader 在对称模式下：

- 用 `jump_index_sym(px0, symClass)` 选择半张跳表
- 若 `ry` 被正规化为正（`mod_positive_256(ry)` 返回 true），则：
  - 距离符号翻转 `dist_toggle_sign_192`
  - `symClass ^= 1`

证据：

- `Kangaroo/GPU/KangarooMetal.metal:89-100`（跳步索引）
- `Kangaroo/GPU/KangarooMetal.metal:793-847`（192-bit 距离符号运算）
- `Kangaroo/GPU/KangarooMetal.metal:1653-1660`（默认核）
- `Kangaroo/GPU/KangarooMetal.metal:2564-2570`（simd 核）

### C. `jacobian` 模式在 symmetry 下被禁用（防止错误路径）

这是一个正确的保守处理。

证据：

- `Kangaroo/GPU/GPUEngineMetal.mm:638-642`

含义：

- 在 `USE_SYMMETRY` 的 135# 场景中，不会误入尚未对称兼容的 jacobian 原型路径
- 运行时 mode 5 会回退到 mode 1

## 4.6 GPU DP -> CPU 碰撞 -> 私钥输出 的最终正确性链路（关键结论）

Metal 只负责推进袋鼠和吐出 DP；**最终密钥正确性由 CPU 统一验证**。

链路如下：

1. Metal kernel 输出 DP (`x`,`d`,`kIdx`)
2. `GPUEngineMetal::Launch()` 解码 DP，恢复 `ITEM`
3. `Kangaroo::SolveKeyGPU()` 用 `kIdx % 2` 推导 `kType`（Tame/Wild）
4. `AddToTable()` 入哈希表；碰撞时触发 `CollisionCheck()`
5. `CollisionCheck()` 取出 `Td/Wd`，调用 `CheckKey()` 尝试 4 种等价关系
6. `CheckKey()` 计算候选 `pk`，回算 `pk*G` 对比 `keyToSearch`/`keyToSearchNeg`
7. 命中后加回 `rangeStart`（对称模式额外加 `rangeWidthDiv2`）
8. `Output()` 再次用 `secp->ComputePublicKey(pk)` 对比原始目标公钥；成功才输出 `Priv`
9. 若指定 `-o`，追加写入结果文件

证据：

- `Kangaroo/Kangaroo.cpp:566-789`（GPU线程主循环）
- `Kangaroo/Kangaroo.cpp:359-383`（GPU DP 入表接口）
- `Kangaroo/Kangaroo.cpp:289-355`（`CollisionCheck`）
- `Kangaroo/Kangaroo.cpp:252-287`（`CheckKey`）
- `Kangaroo/Kangaroo.cpp:218-247`（`Output`）

关键正确性保障：

- 即便出现 DP 假碰撞（如仅存 `x` 低 128 位带来的极低概率误碰撞），`CheckKey()` 和 `Output()` 的公钥回算会拦截错误私钥，不会把错误结果写进输出文件

---

## 5. 断点恢复续跑（`-w/-wi/-ws/-wt` + `-i`）的代码级行为确认

## 5.1 保存机制是否存在并会在 GPU-only / Metal 场景生效

结论：**会生效**。

保存触发路径：

- 统计线程 `Process()` 周期性调用 `SaveWork(...)`
- 与 CPU/GPU worker 通过 `saveRequest + saveMutex` 协作

证据：

- `Kangaroo/Thread.cpp:331-337`
- `Kangaroo/Backup.cpp:536-668`
- CPU 安全点：`Kangaroo/Kangaroo.cpp:540-546`
- GPU 安全点：`Kangaroo/Kangaroo.cpp:749-768`

在你的命令里：

- `-t 0`（无 CPU worker）不影响保存机制，只要 GPU worker 存在即可
- `-ws` 使 GPU worker 在保存时调用 `gpu->GetKangaroos(...)` 回读设备状态

证据：

- `Kangaroo/Kangaroo.cpp:750-763`

## 5.2 `-ws` 对“真正断点续跑”的意义（必须区分）

### A. 有 `-ws`

保存内容包括：

- workfile header（范围/目标/计数/时间）
- hash table（所有已记录 DP）
- `nbLoadedWalk`
- 每只 kangaroo 的 `x/y/d`（以及 symmetry 模式下 `symClass`）

证据：

- `Kangaroo/Backup.cpp:609-648`
- `Kangaroo/Backup.cpp:624-635`

加载后：

- `LoadWork()` 读 header + hash table + `nbLoadedWalk`
- `FectchKangaroos()` 将保存的 walker 状态分配给当前 CPU/GPU 线程结构

证据：

- `Kangaroo/Backup.cpp:149-237`
- `Kangaroo/Backup.cpp:342-445`

### B. 没有 `-ws`

保存内容只有：

- header + hash table
- `nbLoadedWalk=0`

证据：

- `Kangaroo/Backup.cpp:644-648`

加载后行为：

- 哈希表与累计计数/时间会恢复
- 但没有保存的袋鼠状态，worker 会重新 `CreateHerd()` 生成新袋鼠

这属于“**从已积累 DP 表继续搜索**”，不是“逐步等价续跑”。

## 5.3 workfile 版本与高位/对称路径兼容性（你场景的硬门槛）

在 `USE_SYMMETRY` 构建下：

- `LoadWork()` 要求 `loadedWorkVersion >= 2`
- 否则明确报错并拒绝加载

证据：

- `Kangaroo/Backup.cpp:200-211`

在当前代码中，`v2` 对应你需要的 192-bit 距离格式与 symmetry 路径。

## 5.4 恢复分配的“精确续跑”边界（配置变化会破坏严格等价）

`FectchKangaroos()` 的策略是按“**当前运行配置**”分配保存的袋鼠：

- 先按每个 CPU 线程分 `CPU_GRP_SIZE`
- 再按每个 GPU 线程当前 `nbKangaroo`
- 不足则新建
- 多余则发出 `unhandled kangaroos` 警告（保存的状态无法全部消费）

证据：

- `Kangaroo/Backup.cpp:365-439`

这意味着：

- 若恢复时更改了 `-g`（线程组配置）
- 或更改了 `KANGAROO_METAL_GRP_SIZE`（Metal 算法组大小）
- 或改变 CPU/GPU worker 数量

则恢复是“**部分精确 + 部分重建**”，不是严格位级等价续跑。

建议（从代码行为出发）：

- 想获得最接近“精确续跑”的效果，应保持同一二进制、同一 `-g`、同一 `KANGAROO_METAL_GRP_SIZE`、同一 symmetry 编译开关

## 5.5 `-wt` 超时行为（边界）

`SaveWork()` 会等待所有 worker 进入等待态；若超时：

- 打印 `SaveWork timeout !`
- 放弃本次保存
- 不会写入新快照

证据：

- `Kangaroo/Backup.cpp:546-560`

这意味着：

- 周期保存并非“必定成功”
- 实际可恢复点是最近一次成功保存的文件

## 5.6 `-i` 与 `-d` 同时使用的行为（文档通常会漏）

`LoadWork()` 读取 workfile 中保存的 `dp`，但只有在 `initDPSize < 0` 时才采用文件值。

源码行为：

- 若命令行显式提供 `-d`，则 `initDPSize` 已有值，恢复时不会被 workfile 覆盖

证据：

- `Kangaroo/main.cpp:192-195`（设置 `dp`）
- `Kangaroo/Backup.cpp:166-169`（仅 `initDPSize < 0` 时读取到 `initDPSize`）

影响：

- 允许你在续跑时改 DP 位数（代码允许）
- 但这会改变后续新采样 DP 的密度与性能特征

---

## 6. 关键边界情况与风险点（重点回答“注意不要遗漏边界情况”）

## 6.1 [重要] GPU/Metal 保存快照并非严格“hash table + walker state”原子一致（存在一launch DP滞后）

这是本次核验中最关键、最容易被文档忽略的边界。

### 现象来源（代码行为）

`Metal` 的 `GPUEngine::Launch()` 使用流水线：

- 先提交下一次 kernel
- 再等待并解析上一次 kernel 的输出

证据：

- `Kangaroo/GPU/GPUEngineMetal.mm:1656-1669`
- `Kangaroo/GPU/GPUEngineMetal.mm:1704-1748`

GPU worker 在每次循环里执行顺序是：

1. `gpu->Launch(gpuFound)`（解析“上一轮”DP，同时提交“下一轮”kernel）
2. 把 `gpuFound` 入哈希表
3. 如触发保存，`gpu->GetKangaroos(...)` 会等待当前 inflight kernel 完成并读取最新设备状态

证据：

- `Kangaroo/Kangaroo.cpp:668-745`
- `Kangaroo/Kangaroo.cpp:749-763`
- `Kangaroo/GPU/GPUEngineMetal.mm:1387-1392`（`GetKangaroos` 等待 inflight）

### 结果

在保存瞬间可能出现：

- **袋鼠状态**已经包含“当前 inflight kernel”执行后的结果
- 但该 kernel 的 **DP 输出**尚未被 host 解码并加入 hash table（因为要等下一次 `Launch()` 才解析）

即：

- 快照可能漏掉“最近一次 inflight kernel”的 DP 入表

### 影响评估

- **不影响最终正确性**（不会导致错误私钥输出）
- 但会影响“完全精确快照”的语义（续跑后可能丢失少量本应已记录的 DP）
- 可能带来轻微性能回退（漏掉的 DP 需要后续重新遇到才会产生相同碰撞机会）

说明：

- CUDA 路径也采用类似流水式 `Launch()`（返回时已提交下一轮 kernel），因此同类边界在 CUDA 侧也存在

## 6.2 [重要] `USE_SYMMETRY` 编译开关不一致的跨二进制续跑风险

当前 workfile header 主要记录版本号，不显式记录“本文件是否由 symmetry 构建生成”。

代码行为：

- 对称构建写 `version=2`
- 非对称构建写 `version=1`
- 非对称构建加载 `version>=1` 不会直接拒绝 `v2`

证据：

- `Kangaroo/Backup.cpp:449-466`
- `Kangaroo/Backup.cpp:203-221`

风险：

- 用非对称构建去加载 symmetry 生成的 `v2` workfile，版本检查可能通过
- 但搜索语义（`InitSearchKey()` 中点偏移、距离符号解释、碰撞等价关系）不同，续跑结果不可信

结论：

- 对你当前 `Metal 135#` 场景，应使用同一 `USE_SYMMETRY` 构建版本续跑

## 6.3 [中重要] 输出文件写失败不影响屏幕出钥与终止

`Output()` 的行为是：

- 先在 stdout 打印结果
- 再尝试 `fopen(outputFile, "a")`
- 若文件打开失败，只打印错误，不回滚 `endOfSearch`

证据：

- `Kangaroo/Kangaroo.cpp:218-247`

含义：

- 即使 `-o` 路径不可写，程序仍会在屏幕打印正确私钥并结束搜索
- 风险只是“文件落盘失败”，不是“错误出钥”

## 6.4 [中重要] `-g` 显式给值时不会在 `Run()` 阶段做硬件上限校验

`GetGridSize()` 对显式正数参数会直接返回 true；真正的线程组限制校验在 Metal pipeline 构建阶段进行。

证据：

- `Kangaroo/GPU/GPUEngineMetal.mm:824-829`
- `Kangaroo/GPU/GPUEngineMetal.mm:650-660`

影响：

- `-g 80,256` 若设备/内核组合不支持，会在 `GPUEngine` 构造或首轮 kernel 时失败，而不是更早给出参数错误

这不影响正确性，但影响可用性与错误定位体验。

## 6.5 [低概率但必须提] 哈希表仅存 X 低 128 位，可能触发假碰撞

实现事实：

- 哈希表条目只存 `x` 的低 128 位 + 哈希桶索引（来自 `x.bits64[2]` 的低 18 位）
- 不同点极低概率发生误碰撞

证据：

- `Kangaroo/HashTable.h:59-66`
- `Kangaroo/HashTable.cpp:82-109`
- `Kangaroo/HashTable.cpp:272-325`

正确性保障：

- `CollisionCheck()` + `CheckKey()` + `Output()` 的公钥回算会拦截错误私钥
- 异常碰撞还会打印诊断信息并重置相关袋鼠

证据：

- `Kangaroo/Kangaroo.cpp:289-355`
- `Kangaroo/Kangaroo.cpp:218-247`

---

## 7. 底层指令与算术实现核验（满足“需要到底层指令集”要求）

## 7.1 CPU（x86_64 / ARM64）

`SECPK1/Int.h` 已明确区分 ARM64 与 x86_64 路径：

- ARM64（Apple Silicon）：用 `__int128/__uint128_t` 实现 `_umul128/_mul128/_udiv128`，并用 `mrs cntvct_el0` 实现高精度计时
- x86_64：使用内联汇编 `mulq/imulq/divq/rdtsc` 与 `addcarry/sbb` builtin

证据：

- `Kangaroo/SECPK1/Int.h:216-301`

结论：

- 文档中“迁移到 Metal 后 CPU 侧 Apple Silicon 指令路径已适配”的判断成立

## 7.2 CPU 模逆与 secp256k1 特化约减

`Int::ModInv()` 当前启用 `DRS62`（Delayed Right Shift 62 + DivStep62/Pornin 风格）路径：

- `DivStep62()`：`Kangaroo/SECPK1/IntMod.cpp:131-314`
- `ModInv()`：`Kangaroo/SECPK1/IntMod.cpp:317-480`

`Int::ModMulK1()/ModSquareK1()` 使用 secp256k1 常数 `0x1000003D1` 做特化约减：

- `ModMulK1`：`Kangaroo/SECPK1/IntMod.cpp:822-900`
- `ModSquareK1`：`Kangaroo/SECPK1/IntMod.cpp:979-...`

结论：

- 你文档中关于“CPU 底层为 secp 特化 + 进位链优化”的主张成立

## 7.3 CUDA（PTX）

`GPUMath.h` 使用 PTX 内联汇编宏实现热路径算术：

- `add.cc/addc/sub.cc/subc`
- `mul.lo/mul.hi`
- `mad.hi/madc.hi`

证据：

- `Kangaroo/GPU/GPUMath.h:26-48`

对称路径的 192-bit 距离运算（与 Metal 语义同构）也已存在：

- `DistAddSigned192`：`Kangaroo/GPU/GPUMath.h:575-630`
- `DistToggleSign192`：`Kangaroo/GPU/GPUMath.h:632-638`

## 7.4 Metal（MSL）

Metal 无内联汇编，采用 C/MSL 风格显式进位链与 32-bit 分块宽乘：

- `addcarry_u64/subborrow_u64`：`Kangaroo/GPU/KangarooMetal.metal:103-116`
- `mul64wide_u32`：`Kangaroo/GPU/KangarooMetal.metal:119-151`
- `mod_inv_pow_k1 / mod_inv_grouped / mod_inv_grouped_simd`：`Kangaroo/GPU/KangarooMetal.metal:1048+`, `1198+`, `1237+`

结论：

- 文档中“Metal 不是简单翻译 CUDA，而是有独立优化框架与算术路径”的判断成立

---

## 8. 最终结论（针对你的目标直接回答）

## 8.1 关于“Metal 设备求解高位 135# 谜题”

结论：**当前代码逻辑支持，且关键链路正确**（前提是使用 `USE_SYMMETRY + 192-bit` 的当前构建）。

原因（代码证据链已核验）：

- 高位支持核心在 192-bit 距离与 DP/Hash/workfile 一致升级
- Metal `symClass + 192-bit` 路径与 CPU/CUDA 语义对齐
- `jacobian` 非对称原型路径在 symmetry 下被主动禁用，降低错误风险
- 最终出钥由 CPU 统一回算公钥验证，不依赖 GPU 结果“直接信任”

## 8.2 关于“断点恢复续跑求解”

结论：**逻辑成立，但需区分恢复语义层级**。

- `-ws + -i`：支持恢复袋鼠状态，属于“真正的状态续跑”
- 无 `-ws`：只能恢复 hash table 与计数，不是严格状态续跑
- 即便有 `-ws`，在 GPU/Metal 流水化 `Launch()` 下，workfile 快照可能漏掉最近一轮 inflight kernel 的 DP 入表（不影响最终正确性，但影响严格快照一致性）

## 8.3 关于“求解成功后能准确输出密钥”

结论：**能**（就代码逻辑而言）。

直接保障机制：

- 碰撞后 `CheckKey()` 枚举 4 种等价关系并回算候选 `pk*G`
- `Output()` 再次对比原始目标公钥，不相等则拒绝输出私钥
- 只有验证通过才打印 `Priv` 并写入 `-o` 文件（追加模式）

---

## 9. 对两份文档的使用建议（仅文档层面）

建议优先级：

1. 以 `Kangaroo/ALGORITHM_TECH_DOC_CODE_ONLY_PUZZLE135_CN_20260225.md` 作为主文档
2. 用本报告修正其“续跑快照一致性边界 / 运行默认 mode 语义 / 配置变化续跑边界”等补充点
3. 对 `Kangaroo/ALGORITHM_TECH_DOC.md`：
   - Metal 模式映射、Puzzle135 参数估算、总袋鼠数估算等章节应标记为过时/待修订
   - 未修订前不建议用于指导 Metal 135# 调参或续跑策略

---

## 10. 可选的无代码改动验证建议（便于你后续自证）

这些不是必须，但对长期跑 `135#` 很有价值：

- 跑一次 `-check`（会执行 `Dist192 self-test`、Metal unit tests、GPU/CPU 行走对齐）
  - 证据入口：`Kangaroo/Check.cpp:538-565`, `Kangaroo/Check.cpp:553-760`
- 用较小测试区间做一次 `-ws` 保存 -> `-i` 恢复，观察：
  - `LoadWork` 版本/HashTable 信息
  - `FectchKangaroos` 的 loaded/created 统计
  - 恢复后 `stateCache` 实际选择日志（Metal）
- 恢复时保持相同 `-g` 与 `KANGAROO_METAL_GRP_SIZE`，避免“部分恢复 + 部分新建”造成观测误差

