# Puzzle 54 GPU 求解结果
Key# 0 [1S]Pub:  0x034AF4B81F8C450C2C870CE1DF184AFF1297E5FCD54944D98D81E1A545FFB22596 
       Priv: 0x236FB6D5AD1F43 

---

# 目前 500.60 MK/s 最优！！！

## 环境变量说明
# KANGAROO_METAL_STATE_CACHE_MODE  — GPU kernel 模式选择（1=nocache, 4=simd cooperative inversion）
# KANGAROO_METAL_BLOCK_WAIT        — 设为1时 CPU 阻塞等待 GPU 完成（而非轮询超时）
# KANGAROO_METAL_GRP_SIZE          — 每个线程处理的 kangaroo 数量（GPU group size）
# KANGAROO_METAL_NB_RUN            — 每次 kernel dispatch 内的迭代轮数
# KANGAROO_METAL_WAIT_TIMEOUT_MS   — 非阻塞模式下的超时时间（毫秒）
# KANGAROO_METAL_PROFILE           — 启用 GPU 性能计时
# KANGAROO_METAL_INV_PROFILE       — 启用模逆运算的详细统计
# KANGAROO_METAL_AUTO_MODE14_*     — 自动在 mode1 和 mode4 之间进行基准测试并选择更快的

## 程序参数说明
# -gpu         — 启用 GPU 计算
# -gpuId 0     — 使用第 0 号 GPU
# -g 80,256    — GPU 网格大小：80 个 threadgroup × 256 threads/group
# -d N         — Distinguished Point 的位数（N 越大 DP 越稀少，内存占用越小，但碰撞检测越慢）
# -t 0         — CPU 线程数为 0（纯 GPU 模式）
# -o file      — 找到私钥后输出到此文件
# -w file      — 指定 workfile 路径（用于保存/恢复进度）
# -wi N        — 自动保存间隔，单位秒（如 600 = 每10分钟保存一次）
# -ws          — 保存时同时保存 kangaroo 状态（用于断点续跑）
# -wt N        — SaveWork 超时限制（毫秒），超时则跳过本次保存
# -i file      — 从 workfile 加载历史进度（续跑时使用）
# -winfo file  — 查看 workfile 的统计信息（DP数量、步数、时间等）
# -wcheck file — 校验 workfile 中 kangaroo 数据的完整性
# puzzle*.txt  — 输入文件，包含搜索范围和目标公钥

---

## 1. 非对称模式基准测试（mode 1, 无 workfile 保存）
```bash
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo && \
unset KANGAROO_METAL_PROFILE KANGAROO_METAL_INV_PROFILE && \  # 关闭性能分析
KANGAROO_METAL_STATE_CACHE_MODE=1 \   # 强制使用 mode 1 (kangaroo_step_nocache)
KANGAROO_METAL_BLOCK_WAIT=1 \         # CPU 阻塞等待 GPU
KANGAROO_METAL_GRP_SIZE=64 \          # 每线程 64 只 kangaroo
KANGAROO_METAL_NB_RUN=4 \             # 每次 dispatch 跑 4 轮
KANGAROO_METAL_WAIT_TIMEOUT_MS=8000 \ # 超时 8 秒
./kangaroo -gpu -gpuId 0 -g 80,256 \  # 纯 GPU 模式，网格 80×256
  -d 46 \                              # DP bits=46（较大，适合大搜索空间）
  -t 0 \                               # 不使用 CPU 线程
  -o puzzle135_result.txt \             # 结果输出文件
  puzzle135.txt                         # 输入：puzzle 135 的搜索范围和公钥
```

---

## 2. 对称性求解、首次启动，创建并周期保存
```bash
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
make gpu=1 sym=1 -j4                   # 编译：启用 GPU + 对称性优化，4线程并行编译

unset KANGAROO_METAL_STATE_CACHE_MODE KANGAROO_METAL_NO_STATE_CACHE KANGAROO_METAL_DISABLE_AUTO_MODE14
                                       # 清除旧的模式设置，启用自动模式选择

KANGAROO_METAL_AUTO_MODE14_WARMUP=1 \  # 自动基准测试前预热 1 轮
KANGAROO_METAL_AUTO_MODE14_ITERS=2 \   # 基准测试迭代 2 轮
KANGAROO_METAL_AUTO_MODE14_MIN_GAIN_PCT=0 \ # mode4 只要不比 mode1 慢就选 mode4
KANGAROO_METAL_BLOCK_WAIT=1 \
KANGAROO_METAL_GRP_SIZE=64 \
KANGAROO_METAL_NB_RUN=4 \
KANGAROO_METAL_WAIT_TIMEOUT_MS=8000 \
./kangaroo -gpu -gpuId 0 -g 80,256 \
  -d 43 \                              # DP bits=43（puzzle 135 的推荐值附近）
  -t 0 \
  -w /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135.work \  # workfile 路径
  -wi 600 \                            # 每 600 秒(10分钟)自动保存
  -ws \                                # 保存 kangaroo 状态（用于断点续跑）
  -wt 15000 \                          # SaveWork 超时 15 秒
  -o /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135_result.txt \
  /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135.txt  # 首次启动需要指定输入文件
```

---

## 3. 重启续跑（加载历史数据并继续保存到同一个 workfile）
```bash
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
make gpu=1 sym=1 -j4

unset KANGAROO_METAL_STATE_CACHE_MODE KANGAROO_METAL_NO_STATE_CACHE KANGAROO_METAL_DISABLE_AUTO_MODE14
KANGAROO_METAL_AUTO_MODE14_WARMUP=1 \
KANGAROO_METAL_AUTO_MODE14_ITERS=2 \
KANGAROO_METAL_AUTO_MODE14_MIN_GAIN_PCT=0 \
KANGAROO_METAL_BLOCK_WAIT=1 \
KANGAROO_METAL_GRP_SIZE=64 \
KANGAROO_METAL_NB_RUN=4 \
KANGAROO_METAL_WAIT_TIMEOUT_MS=8000 \
./kangaroo -gpu -gpuId 0 -g 80,256 -t 0 \
  -i /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135.work \  # 从 workfile 加载进度
  -w /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135.work \  # 继续保存到同一个 workfile
  -wi 600 -ws -wt 15000 \
  -o /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135_result.txt
  # 注意：续跑时不需要指定 puzzle135.txt，搜索参数从 workfile 中读取
```

---

## 4. 查看/校验 workfile
```bash
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo

# 查看 workfile 统计信息（DP数量、总步数、运行时间、kangaroo数量等）
./kangaroo -winfo /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135.work

# 校验 workfile 中 kangaroo 数据的完整性
./kangaroo -wcheck /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135.work
```
> ⚠️ 停机前建议先看到一条 `SaveWork: ... done`，再停止进程（Ctrl+C），避免数据丢失。

---

## 5. Puzzle 54 验证（用小 puzzle 快速验证 GPU 计算正确性）
```bash
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
make gpu=1 sym=1 -j4

unset KANGAROO_METAL_NO_STATE_CACHE KANGAROO_METAL_DISABLE_AUTO_MODE14
KANGAROO_METAL_STATE_CACHE_MODE=1 \   # 强制 mode 1
KANGAROO_METAL_BLOCK_WAIT=1 \
KANGAROO_METAL_GRP_SIZE=64 \
KANGAROO_METAL_NB_RUN=4 \
KANGAROO_METAL_WAIT_TIMEOUT_MS=8000 \
./kangaroo -gpu -gpuId 0 -g 80,256 \
  -d 6 \                              # DP bits=6（puzzle 54 搜索空间小，用小 DP 值加速）
  -t 0 \
  -o puzzle54_verify_gpu_result.txt \
  puzzle54.txt                         # puzzle 54 输入文件
```
