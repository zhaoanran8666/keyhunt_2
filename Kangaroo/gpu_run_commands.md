Key# 0 [1S]Pub:  0x034AF4B81F8C450C2C870CE1DF184AFF1297E5FCD54944D98D81E1A545FFB22596 
       Priv: 0x236FB6D5AD1F43 

目前 500.60 MK/s 最优！！！
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo && \
unset KANGAROO_METAL_PROFILE KANGAROO_METAL_INV_PROFILE && \
KANGAROO_METAL_STATE_CACHE_MODE=1 KANGAROO_METAL_BLOCK_WAIT=1 \
KANGAROO_METAL_GRP_SIZE=64 KANGAROO_METAL_NB_RUN=4 KANGAROO_METAL_WAIT_TIMEOUT_MS=8000 \
./kangaroo -gpu -gpuId 0 -g 80,256 -d 46 -t 0 -o puzzle135_result.txt puzzle135.txt

# 对称性求解、首次启动，创建并周期保存
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
unset KANGAROO_METAL_STATE_CACHE_MODE KANGAROO_METAL_NO_STATE_CACHE KANGAROO_METAL_DISABLE_AUTO_MODE14
KANGAROO_METAL_AUTO_MODE14_WARMUP=1 KANGAROO_METAL_AUTO_MODE14_ITERS=2 KANGAROO_METAL_AUTO_MODE14_MIN_GAIN_PCT=0 \
KANGAROO_METAL_BLOCK_WAIT=1 KANGAROO_METAL_GRP_SIZE=64 KANGAROO_METAL_NB_RUN=4 KANGAROO_METAL_WAIT_TIMEOUT_MS=8000 \
./kangaroo -gpu -gpuId 0 -g 80,256 -d 44 -t 0 \
-w /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135.work -wi 60 -ws -wt 15000 \
-o /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135_result.txt \
/Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135.txt

cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
unset KANGAROO_METAL_STATE_CACHE_MODE KANGAROO_METAL_NO_STATE_CACHE KANGAROO_METAL_DISABLE_AUTO_MODE14
KANGAROO_METAL_AUTO_MODE14_WARMUP=1 KANGAROO_METAL_AUTO_MODE14_ITERS=2 KANGAROO_METAL_AUTO_MODE14_MIN_GAIN_PCT=0 \
KANGAROO_METAL_BLOCK_WAIT=1 KANGAROO_METAL_GRP_SIZE=64 KANGAROO_METAL_NB_RUN=4 KANGAROO_METAL_WAIT_TIMEOUT_MS=8000 \
./kangaroo -gpu -gpuId 0 -g 80,256 -d 44 -t 0 \
-w /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135.work -wi 1200 -ws -wt 15000 \
-o /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135_result.txt \
/Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135.txt


# 重启续跑（加载历史数据并继续保存到同一个 workfile）
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
unset KANGAROO_METAL_STATE_CACHE_MODE KANGAROO_METAL_NO_STATE_CACHE KANGAROO_METAL_DISABLE_AUTO_MODE14
KANGAROO_METAL_AUTO_MODE14_WARMUP=1 KANGAROO_METAL_AUTO_MODE14_ITERS=2 KANGAROO_METAL_AUTO_MODE14_MIN_GAIN_PCT=0 \
KANGAROO_METAL_BLOCK_WAIT=1 KANGAROO_METAL_GRP_SIZE=64 KANGAROO_METAL_NB_RUN=4 KANGAROO_METAL_WAIT_TIMEOUT_MS=8000 \
./kangaroo -gpu -gpuId 0 -g 80,256 -t 0 \
  -i /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135_test.work \
  -w /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135_test.work -wi 600 -ws -wt 15000 \
  -o /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135_result.txt \
  /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135.txt

# 可选：查看/校验 workfile
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
./kangaroo -winfo /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135.work
./kangaroo -wcheck /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135.work
停机前建议先看到一条 SaveWork: ... done，再停止进程。

cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
./kangaroo -winfo /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135_test.work
./kangaroo -wcheck /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135_test.work

# Puzzle 60 验证运行（对称性 + 自动模式选择 + 每秒保存）
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
unset KANGAROO_METAL_STATE_CACHE_MODE KANGAROO_METAL_NO_STATE_CACHE KANGAROO_METAL_DISABLE_AUTO_MODE14
KANGAROO_METAL_AUTO_MODE14_WARMUP=1 KANGAROO_METAL_AUTO_MODE14_ITERS=2 KANGAROO_METAL_AUTO_MODE14_MIN_GAIN_PCT=0 \
KANGAROO_METAL_BLOCK_WAIT=1 KANGAROO_METAL_GRP_SIZE=64 KANGAROO_METAL_NB_RUN=4 KANGAROO_METAL_WAIT_TIMEOUT_MS=8000 \
./kangaroo -gpu -gpuId 0 -g 80,256 -d 6 -t 0 \
  -w /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle60_test.work -wi 15 -ws -wt 15000 \
  -o /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle60_result.txt \
  /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle60.txt

# Puzzle 65 验证运行（对称性 + 自动模式选择 + 每秒保存）
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
unset KANGAROO_METAL_STATE_CACHE_MODE KANGAROO_METAL_NO_STATE_CACHE KANGAROO_METAL_DISABLE_AUTO_MODE14
KANGAROO_METAL_AUTO_MODE14_WARMUP=1 KANGAROO_METAL_AUTO_MODE14_ITERS=2 KANGAROO_METAL_AUTO_MODE14_MIN_GAIN_PCT=0 \
KANGAROO_METAL_BLOCK_WAIT=1 KANGAROO_METAL_GRP_SIZE=64 KANGAROO_METAL_NB_RUN=4 KANGAROO_METAL_WAIT_TIMEOUT_MS=8000 \
./kangaroo -gpu -gpuId 0 -g 80,256 -d 9 -t 0 \
  -w /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle65_test.work -wi 300 -ws -wt 15000 \
  -o /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle65_result.txt \
  /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle65.txt

# Puzzle 70 验证运行（对称性 + 自动模式选择 + 每秒保存）
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
unset KANGAROO_METAL_STATE_CACHE_MODE KANGAROO_METAL_NO_STATE_CACHE KANGAROO_METAL_DISABLE_AUTO_MODE14
KANGAROO_METAL_AUTO_MODE14_WARMUP=1 KANGAROO_METAL_AUTO_MODE14_ITERS=2 KANGAROO_METAL_AUTO_MODE14_MIN_GAIN_PCT=0 \
KANGAROO_METAL_BLOCK_WAIT=1 KANGAROO_METAL_GRP_SIZE=128 KANGAROO_METAL_NB_RUN=4 KANGAROO_METAL_WAIT_TIMEOUT_MS=8000 \
./kangaroo -gpu -gpuId 0 -g 80,256 -d 11 -t 0 \
  -w /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle70_test.work -wi 120 -ws -wt 15000 \
  -o /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle70_result.txt \
  puzzle70.txt

# Puzzle 75 验证运行（对称性 + 自动模式选择 + 每秒保存）
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
unset KANGAROO_METAL_STATE_CACHE_MODE KANGAROO_METAL_NO_STATE_CACHE KANGAROO_METAL_DISABLE_AUTO_MODE14
KANGAROO_METAL_AUTO_MODE14_WARMUP=1 KANGAROO_METAL_AUTO_MODE14_ITERS=2 KANGAROO_METAL_AUTO_MODE14_MIN_GAIN_PCT=0 \
KANGAROO_METAL_BLOCK_WAIT=1 KANGAROO_METAL_GRP_SIZE=128 KANGAROO_METAL_NB_RUN=4 KANGAROO_METAL_WAIT_TIMEOUT_MS=8000 \
./kangaroo -gpu -gpuId 0 -g 80,256 -t 0 \
  -w /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle75_test.work -wi 300 -ws -wt 15000 \
  -o /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle75_result.txt \
  puzzle75.txt

# Puzzle 95
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
unset KANGAROO_METAL_STATE_CACHE_MODE KANGAROO_METAL_NO_STATE_CACHE KANGAROO_METAL_DISABLE_AUTO_MODE14
KANGAROO_METAL_AUTO_MODE14_WARMUP=1 KANGAROO_METAL_AUTO_MODE14_ITERS=2 KANGAROO_METAL_AUTO_MODE14_MIN_GAIN_PCT=0 \
KANGAROO_METAL_BLOCK_WAIT=1 KANGAROO_METAL_GRP_SIZE=128 KANGAROO_METAL_NB_RUN=4 KANGAROO_METAL_WAIT_TIMEOUT_MS=8000 \
./kangaroo -gpu -gpuId 0 -g 80,256 -d 11 -t 0 \
  -w /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle95_test.work -wi 300 -ws -wt 15000 \
  -o /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle95_result.txt \
  /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle95.txt

# Puzzle 100
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
unset KANGAROO_METAL_STATE_CACHE_MODE KANGAROO_METAL_NO_STATE_CACHE KANGAROO_METAL_DISABLE_AUTO_MODE14
KANGAROO_METAL_AUTO_MODE14_WARMUP=1 KANGAROO_METAL_AUTO_MODE14_ITERS=2 KANGAROO_METAL_AUTO_MODE14_MIN_GAIN_PCT=0 \
KANGAROO_METAL_BLOCK_WAIT=1 KANGAROO_METAL_GRP_SIZE=128 KANGAROO_METAL_NB_RUN=4 KANGAROO_METAL_WAIT_TIMEOUT_MS=8000 \
./kangaroo -gpu -gpuId 0 -g 80,256 -t 0 \
  -w /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle100_test.work -wi 300 -ws -wt 15000 \
  -o /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle100_result.txt \
  /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle100.txt

# Puzzle 110
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
unset KANGAROO_METAL_STATE_CACHE_MODE KANGAROO_METAL_NO_STATE_CACHE KANGAROO_METAL_DISABLE_AUTO_MODE14
KANGAROO_METAL_AUTO_MODE14_WARMUP=1 KANGAROO_METAL_AUTO_MODE14_ITERS=2 KANGAROO_METAL_AUTO_MODE14_MIN_GAIN_PCT=0 \
KANGAROO_METAL_BLOCK_WAIT=1 KANGAROO_METAL_GRP_SIZE=128 KANGAROO_METAL_NB_RUN=4 KANGAROO_METAL_WAIT_TIMEOUT_MS=8000 \
./kangaroo -gpu -gpuId 0 -g 80,256 -t 0 \
  -w /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle110_test.work -wi 300 -ws -wt 15000 \
  -o /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle110_result.txt \
  /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle110.txt

# Puzzle 120
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
unset KANGAROO_METAL_STATE_CACHE_MODE KANGAROO_METAL_NO_STATE_CACHE KANGAROO_METAL_DISABLE_AUTO_MODE14
KANGAROO_METAL_AUTO_MODE14_WARMUP=1 KANGAROO_METAL_AUTO_MODE14_ITERS=2 KANGAROO_METAL_AUTO_MODE14_MIN_GAIN_PCT=0 \
KANGAROO_METAL_BLOCK_WAIT=1 KANGAROO_METAL_GRP_SIZE=128 KANGAROO_METAL_NB_RUN=4 KANGAROO_METAL_WAIT_TIMEOUT_MS=8000 \
./kangaroo -gpu -gpuId 0 -g 80,256 -t 0 \
  -w /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle120_test.work -wi 1200 -ws -wt 15000 \
  -o /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle120_result.txt \
  /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle120.txt

# Puzzle 130
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
unset KANGAROO_METAL_STATE_CACHE_MODE KANGAROO_METAL_NO_STATE_CACHE KANGAROO_METAL_DISABLE_AUTO_MODE14
KANGAROO_METAL_AUTO_MODE14_WARMUP=1 KANGAROO_METAL_AUTO_MODE14_ITERS=2 KANGAROO_METAL_AUTO_MODE14_MIN_GAIN_PCT=0 \
KANGAROO_METAL_BLOCK_WAIT=1 KANGAROO_METAL_GRP_SIZE=128 KANGAROO_METAL_NB_RUN=4 KANGAROO_METAL_WAIT_TIMEOUT_MS=8000 \
./kangaroo -gpu -gpuId 0 -g 80,256 -t 0 \
  -w /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle130_test.work -wi 1200 -ws -wt 15000 \
  -o /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle130_result.txt \
  /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle130.txt

# Puzzle 130_quick65
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
unset KANGAROO_METAL_STATE_CACHE_MODE KANGAROO_METAL_NO_STATE_CACHE KANGAROO_METAL_DISABLE_AUTO_MODE14
KANGAROO_METAL_AUTO_MODE14_WARMUP=1 KANGAROO_METAL_AUTO_MODE14_ITERS=2 KANGAROO_METAL_AUTO_MODE14_MIN_GAIN_PCT=0 \
KANGAROO_METAL_BLOCK_WAIT=1 KANGAROO_METAL_GRP_SIZE=128 KANGAROO_METAL_NB_RUN=4 KANGAROO_METAL_WAIT_TIMEOUT_MS=8000 \
./kangaroo -gpu -gpuId 0 -g 80,256 -t 0 \
  -w /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle130_quick65.work -wi 60 -ws -wt 15000 \
  -o /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle130_quick65_result.txt \
  /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle130_quick65.txt

# Puzzle 135
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
unset KANGAROO_METAL_STATE_CACHE_MODE KANGAROO_METAL_NO_STATE_CACHE KANGAROO_METAL_DISABLE_AUTO_MODE14
KANGAROO_METAL_AUTO_MODE14_WARMUP=1 KANGAROO_METAL_AUTO_MODE14_ITERS=2 KANGAROO_METAL_AUTO_MODE14_MIN_GAIN_PCT=0 \
KANGAROO_METAL_BLOCK_WAIT=1 KANGAROO_METAL_GRP_SIZE=128 KANGAROO_METAL_NB_RUN=2 KANGAROO_METAL_WAIT_TIMEOUT_MS=8000 \
./kangaroo -gpu -gpuId 0 -g 80,256 -d 43 -t 0 \
  -w /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135_test_d22.work -wi 1800 -ws -wt 15000 \
  -o /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135_result.txt \
  /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135.txt

# Puzzle 135重启续跑 2月25日 NB_RUN=1 提升7%，不影响续跑。从merged续跑
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
unset KANGAROO_METAL_STATE_CACHE_MODE KANGAROO_METAL_NO_STATE_CACHE KANGAROO_METAL_DISABLE_AUTO_MODE14
KANGAROO_METAL_AUTO_MODE14_WARMUP=1 KANGAROO_METAL_AUTO_MODE14_ITERS=2 KANGAROO_METAL_AUTO_MODE14_MIN_GAIN_PCT=0 \
KANGAROO_METAL_BLOCK_WAIT=1 KANGAROO_METAL_GRP_SIZE=128 KANGAROO_METAL_NB_RUN=1 KANGAROO_METAL_WAIT_TIMEOUT_MS=8000 \
./kangaroo -gpu -gpuId 0 -g 80,256 -t 0 \
  -i /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135_merged.work \
  -w /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135_test.work -wi 1800 -ws -wt 15000 \
  -o /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135_result.txt \
  /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135.txt


# *** 查看 workfile 确认 DP Count

cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
./kangaroo -winfo /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135_test.work
./kangaroo -wcheck /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135_test.work

# *** 合并 workfile
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo && \
./kangaroo -wm puzzle135_test.work puzzle135_test_gs64_nr96.work puzzle135_merged.work

# 编译
make clean && make gpu=1 sym=1 -j8

# ============================================================
# Puzzle 135 求解预估（DP bits = 43，对称性模式）
# 更新日期：2026-02-26
# ============================================================
#
# 搜索范围：         2^134（Start: 0x4000...0, Stop: 0x7FFF...F）
# 预期总操作数：     2^67.62 ≈ 2.27 × 10^20 次跳跃
# 每个 DP 平均间隔： 2^43 ≈ 8.80 × 10^12 次跳跃
# 预计所需 DP 总量： 2^67.62 / 2^43 = 2^24.62 ≈ 25,787,000 个
#
# --- 设备速度 ---
# Mac Studio (M4 Max 40核GPU)：576.79 MK/s
# Windows (CUDA GPU)：          600 MK/s
# 双机合计：                    1,176.79 MK/s
#
# --- DP 产出速率 ---
# Mac：    每 4.24 小时产出 1 个 DP，每天约 5.67 个
# Windows：每 4.07 小时产出 1 个 DP，每天约 5.90 个
# 双机合计：每天约 11.57 个 DP
#
# --- 预计求解时间 ---
# 仅 Mac：     约 12,462 年
# 仅 Windows： 约 11,974 年
# 双机合力：   约 6,105 年
# ============================================================


# Puzzle75 分步求解，合并文件，试验验证计算

rangePower = 74
kangaroos  = 80 × 256 × 128 = 2,621,440 (2^21.32)
suggestedDP = 74/2 - 21.32 ≈ 16
用 d=14（4% 开销，约 6 分钟解出），-wi 30（30 秒一个 split），预计产生 ~12 个 split 文件。

# 完整验证方案
# 第一步：准备
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
mkdir -p splits_test75

# 第二步：运行（带 -wsplit）
KANGAROO_METAL_AUTO_MODE14_WARMUP=1 KANGAROO_METAL_AUTO_MODE14_ITERS=2 \
KANGAROO_METAL_AUTO_MODE14_MIN_GAIN_PCT=0 KANGAROO_METAL_BLOCK_WAIT=1 \
KANGAROO_METAL_GRP_SIZE=128 KANGAROO_METAL_NB_RUN=1 KANGAROO_METAL_WAIT_TIMEOUT_MS=8000 \
./kangaroo -gpu -gpuId 0 -g 80,256 -d 14 -t 0 \
  -w ./splits_test75/p75.work \
  -wi 30 -wsplit -wt 15000 \
  -o puzzle75_result.txt \
  puzzle75.txt
注意：不加 -ws（不保存袋鼠状态），每个 split 只有 hash table，文件更小（~40 MB/个），6 分钟测试不需要崩溃恢复。

运行过程中你会看到类似：
SaveWork: ./splits_test75/p75.work_02Mar26_201500...done [42 MB] [0s]
                                    ↑ 带时间戳的独立文件
可能的两种结果：
结果 A：程序直接输出 Key#0 ... Pub: 0x... → 碰撞在某个 30 秒区间内被检测到，密钥已解出，写入 puzzle75_result.txt
结果 B：程序跑完或手动 Ctrl+C 停止，没有找到密钥 → 碰撞的两个 DP 分散在不同 split 文件中，需要合并

# 第三步：查看 split 文件

ls -lh splits_test75/
你应该看到多个带时间戳的文件：
p75.work_02Mar26_201500   42M
p75.work_02Mar26_201530   41M
p75.work_02Mar26_201600   43M
...

# 第四步：合并检测碰撞
##  用 -wmdir 一次合并整个目录：
./kangaroo -wmdir ./splits_test75/ ./splits_test75/p75_merged.work -o puzzle75_result.txt
合并过程会逐文件配对比较所有 DP。如果碰撞存在，会直接输出密钥：


##  或者定期合并检测碰撞把 splits 目录下所有 work 文件合并到一个目标文件
./kangaroo -wm ./splits/puzzle135.work_02Mar26_180000 \
               ./splits/puzzle135.work_09Mar26_180000 \
               ./merged/puzzle135_merged.work
./kangaroo -wmdir ./splits/ ./merged/puzzle135_all.work
合并时程序会逐桶二分查找比对，碰撞在合并过程中自动检测。如果找到密钥，直接输出。

## File #1/11
## File #2/11
...
Key#0 [tame+wild] Pub: 0x03726B574F...
       Priv: 0x4C5CE114686A1336E07
第五步：验证

# 查看结果文件
cat puzzle75_result.txt

# 查看每个 split 的信息
./kangaroo -winfo ./splits_test75/p75.work_02Mar26_201500
预期时间线

0:00  启动，创建袋鼠
0:13  benchmark 完成，开始搜索
0:30  第 1 个 split 保存，hash table 清空
1:00  第 2 个 split
...
~6:00 期望解出时间
      ├── 运行中直接解出 (结果 A)
      └── 或 ~12 个 split 文件等待合并 (结果 B)
~6:05 -wmdir 合并 (如需要，几秒完成)
解出后，如果方案验证成功，再用同样的 -wsplit 模式对 puzzle135 正式运行。


# ============================================================
# Puzzle135 分步求解，合并文件，崩溃恢复
# 更新日期：2026-03-03
# ============================================================
#
# 选定方案：d=35（开销 ≈ 0.02%，几乎为零）
#
# ┌─────────────────────────────────────────────────────────┐
# │ 关于 -w 与 -wsplit 的技术说明                          │
# │                                                         │
# │ 程序只有一个保存定时器 -wi。                            │
# │ -w file（不加 -wsplit）：定时覆盖同一文件，              │
# │   hash table 不清空，DPs 持续累积。                     │
# │ -w file -wsplit：定时生成带时间戳的新文件，              │
# │   保存后清空 hash table。                               │
# │                                                         │
# │ 两者不能同时使用不同间隔。                              │
# │                                                         │
# │ 本方案采用：-w（单文件）+ -wi 1800（30 分钟覆盖保存）  │
# │ 优点：                                                  │
# │  1. 崩溃最多丢 30 分钟数据                              │
# │  2. 所有 DP 累积在一个文件中，无需合并本机数据          │
# │  3. 跨机器合并只需复制各自的 work 文件到同一目录        │
# └─────────────────────────────────────────────────────────┘

rangePower = 134
kangaroos  = 80 × 256 × 128 = 2,621,440 (2^21.32)
suggestedDP = 134/2 - 21.32 ≈ 45.68
选定 d=35（开销 0.02%，理论磁盘 252 GB / 内存 303 GB）
实际存储：以双机 ~1,177 MK/s 计算，每年仅新增 ~43 MB DP 数据
（详见下方「内存估算」章节）

设备速度：Mac Studio (M4 Max) 576.79 MK/s, Windows (CUDA) ~600 MK/s
DP 产出速率（d=35）：Mac 每 59.6 秒 1 个 DP，Windows 每 57.3 秒 1 个 DP
双机合计：每天 ~2,960 个 DP，每年 ~108 万个

# ============================================================
# 第一步：准备
# ============================================================
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo

# ============================================================
# 第二步：首次运行（Mac Metal）
# ============================================================
# -w file -wi 1800 -ws ：每 30 分钟覆盖保存到同一文件（含袋鼠状态）
# 不加 -wsplit：hash table 不清空，所有 DP 持续累积在一个文件中
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
unset KANGAROO_METAL_STATE_CACHE_MODE KANGAROO_METAL_NO_STATE_CACHE KANGAROO_METAL_DISABLE_AUTO_MODE14
KANGAROO_METAL_AUTO_MODE14_WARMUP=1 KANGAROO_METAL_AUTO_MODE14_ITERS=2 \
KANGAROO_METAL_AUTO_MODE14_MIN_GAIN_PCT=0 KANGAROO_METAL_BLOCK_WAIT=1 \
KANGAROO_METAL_GRP_SIZE=128 KANGAROO_METAL_NB_RUN=1 KANGAROO_METAL_WAIT_TIMEOUT_MS=8000 \
./kangaroo -gpu -gpuId 0 -g 80,256 -d 35 -t 0 \
  -w /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135_d35_Mac.work \
  -wi 1800 -ws -wt 15000 \
  -o /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135_result.txt \
  /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135.txt

# Windows CUDA 端命令（无 Metal 环境变量，其余一致）
# ./kangaroo -gpu -gpuId 0 -g <gridX>,<gridY> -d 35 -t 0 \
#   -w puzzle135_d35_Win.work \
#   -wi 1800 -ws -wt 15000 \
#   -o puzzle135_result.txt \
#   puzzle135.txt

运行过程中你会看到类似：
SaveWork: puzzle135_d35_Mac.work...done [~202 MB] [0s]
  ↑ 每 30 分钟覆盖同一文件

文件组成：
  - 袋鼠状态（-ws）：2,621,440 只 × ~88 字节 ≈ 220 MB（固定）
  - DP 数据：每天 ~1,451 个 × 40 字节 ≈ 58 KB/天（缓慢增长）
  - hash table 开销：~2 MB（固定）
  - 文件大小变化：首日 ~222 MB → 1 年后 ~265 MB → 10 年后 ~655 MB

可能的两种结果：
结果 A：单机碰撞 — 程序直接输出 Key#0 ... Priv: 0x... → 写入 puzzle135_result.txt
结果 B：跨机器碰撞 — 两台机器各自的 DP 之间存在碰撞 → 需要合并检测（见第四步）

# ============================================================
# 第三步：查看 work 文件状态
# ============================================================
./kangaroo -winfo /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/merge_135/puzzle135_d35_Mac.work
./kangaroo -wcheck /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135_d35_Mac.work

./kangaroo -winfo /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/merge_135/puzzle135_test_gs64_nr128_Win.work

./kangaroo -winfo /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/merge_135/puzzle135_d35_merged.work

# 可以看到 DP 数量、运行时间等信息

# ============================================================
# 第四步：跨机器合并检测碰撞（两台电脑）
# ============================================================
# 操作方法：
# 1. 从 Windows 机器拷贝 puzzle135_d35_Win.work 到 Mac（或反过来）
# 2. 将两个文件放到同一个目录下
# 3. 用 -wm 合并
#
# 注意：两台机器的 -d 值必须一致（都是 35），
#       range 和 target key 也必须一致（都读同一个 puzzle135.txt）。
#       合并时程序会逐桶比对所有 DP，自动检测跨机器碰撞。

mkdir -p /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/merge_135

# 将两台电脑的 work 文件复制到 merge_135/ 目录：
# cp <Mac 的 puzzle135_d35.work>     merge_135/puzzle135_d35_Mac.work
# cp <Windows 的 puzzle135_d35.work> merge_135/puzzle135_d35_Win.work

# 合并（碰撞在合并过程中自动检测，找到即输出密钥）
./kangaroo -wm \
  /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/merge_135/puzzle135_d35_Mac.work \
  /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/merge_135/puzzle135_test_gs64_nr128_Win.work \
  /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/merge_135/puzzle135_d35_merged.work \
  -o /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135_result.txt

# 建议合并频率：每周或每月一次
# 合并耗时随 DP 数量增长，前几年每次仅需几秒
# 合并后 merged 文件仅包含 DP（无袋鼠状态），体积远小于原始 work 文件
#
# 合并后各机器继续用各自的 work 文件运行，无需加载 merged 文件
# （merged 文件仅用于跨机器碰撞检测）

# 也可以用 -wmdir 合并整个目录下所有 work 文件
./kangaroo -wmdir \
  /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/merge_135/ \
  /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/merge_135/puzzle135_d35_all.work \
  -o /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135_result.txt

# ============================================================
# 第五步：验证结果
# ============================================================
cat /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135_result.txt
# 预期输出：
# Key# 0 [1S]Pub:  0x02145D2611C823A396EF6712CE0F712F09B9B4F3135E3E0AA3230FB9B6D08D1E16
#        Priv: 0x<私钥十六进制>


# ============================================================
# 崩溃恢复
# ============================================================
# 如果程序意外退出（崩溃、断电、系统重启等）：
# 前提：运行时必须带 -ws 参数（保存袋鼠状态），否则无法恢复袋鼠位置。
#
# 由于使用 -w（单文件覆盖）+ -wi 1800（30 分钟），
# work 文件始终包含：最新袋鼠位置 + 所有累积的 DP。
# 最多丢失 30 分钟的数据。

# 直接用 -i 加载 work 文件恢复
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
unset KANGAROO_METAL_STATE_CACHE_MODE KANGAROO_METAL_NO_STATE_CACHE KANGAROO_METAL_DISABLE_AUTO_MODE14
KANGAROO_METAL_AUTO_MODE14_WARMUP=1 KANGAROO_METAL_AUTO_MODE14_ITERS=2 \
KANGAROO_METAL_AUTO_MODE14_MIN_GAIN_PCT=0 KANGAROO_METAL_BLOCK_WAIT=1 \
KANGAROO_METAL_GRP_SIZE=128 KANGAROO_METAL_NB_RUN=1 KANGAROO_METAL_WAIT_TIMEOUT_MS=8000 \
./kangaroo -gpu -gpuId 0 -g 80,256 -d 35 -t 0 \
  -i /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135_d35_Mac.work \
  -w /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135_d35_Mac.work \
  -wi 1800 -ws -wt 15000 \
  -o /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135_result.txt \
  /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135.txt

cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
unset KANGAROO_METAL_STATE_CACHE_MODE KANGAROO_METAL_NO_STATE_CACHE KANGAROO_METAL_DISABLE_AUTO_MODE14
KANGAROO_METAL_AUTO_MODE14_WARMUP=1 KANGAROO_METAL_AUTO_MODE14_ITERS=2 KANGAROO_METAL_AUTO_MODE14_MIN_GAIN_PCT=0 \
KANGAROO_METAL_BLOCK_WAIT=1 KANGAROO_METAL_GRP_SIZE=128 KANGAROO_METAL_NB_RUN=1 KANGAROO_METAL_WAIT_TIMEOUT_MS=8000 \
./kangaroo -gpu -gpuId 0 -g 80,256 -t 0 \
  -i /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135_merged.work \
  -w /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135_test.work -wi 1800 -ws -wt 15000 \
  -o /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135_result.txt \
  /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135.txt
# 恢复说明：
# -i <file>  ：从 work 文件加载袋鼠位置 + 所有已有 DP
# -w <file>  ：恢复后继续保存到同一文件（覆盖模式）
# 恢复后程序从上次保存的袋鼠位置继续搜索，不会浪费已走的步数。
# 丢失的仅是「上次保存 → 崩溃」之间的 DP（最多 30 分钟的量，约 30 个 DP）。
#
# 注意事项：
# 1. 恢复的 -d 值必须与原始运行一致（都是 35）
# 2. 如果 work 文件损坏（写入中途断电），可尝试从合并目录中的备份恢复
#    建议：每周合并前先 cp puzzle135_d35_Mac.work puzzle135_d35_Mac.work.bak 做备份
# 3. 建议停机前等到 "SaveWork: ... done" 日志后再停止进程


# ============================================================
# 内存估算与存储空间
# ============================================================
#
# 估算公式（来源：Kangaroo.cpp:981-1018 ComputeExpected）
#
# 条件：USE_SYMMETRY, rangePower=134, kangaroos=2^21.32
#
# gainS    = 1/√2 ≈ 0.7071
# Z0       = 2 × (2 - √2) × gainS × √π ≈ 1.4683
# N        = 2^134（搜索范围宽度）
# theta    = 2^d （DP 间隔）
# k        = 2^21.32（袋鼠数量）
#
# 总操作数  op       = Z0 × (N × (k × theta + √N))^(1/3)
# 预期 DP 数 nbDP    = op / theta
# DP 开销   overhead = (1 + k × theta / √N)^(1/3) - 1
#
# --- 磁盘（work 文件）---
# 每个 DP：40 字节（ENTRY = 16B X坐标 + 24B 距离）
# hash 桶开销：262,144 桶 × 8 字节 = 2 MB（固定）
# 文件头：156 字节（固定）
# 磁盘总量 ≈ 2 MB + nbDP × 40 字节
#
# --- 内存（运行/合并时 RAM）---
# hash 表基础：HASH_ENTRY × HASH_SIZE = 16 × 262,144 = 4 MB
# 分配开销：ENTRY_PTR × HASH_SIZE × 4 = 8 × 262,144 × 4 = 8 MB
# DP 条目：(ENTRY + ENTRY_PTR) × nbDP = 48 × nbDP
# 内存总量 ≈ 12 MB + nbDP × 48 字节
#
# --- 袋鼠状态（-ws 保存时额外占用）---
# 每只袋鼠：~88 字节（x 32B + y 32B + d 24B）
# 2,621,440 × 88 ≈ 220 MB（work 文件的固定开销）
#
# ┌──────┬──────────┬──────────────┬────────────┬────────────┬──────────────────────────────────────┐
# │  d   │ DP 开销  │ 预期 DP(理论)│ 磁盘(理论) │ 内存(理论) │ 说明                                 │
# ├──────┼──────────┼──────────────┼────────────┼────────────┼──────────────────────────────────────┤
# │ *35  │  0.02%   │  6,310 M     │  252 GB    │  303 GB    │ ★ 选定：开销最低，实际年增仅 43 MB   │
# │  38  │  0.16%   │    789 M     │   32 GB    │   38 GB    │                                      │
# │  40  │  0.65%   │    198 M     │    8 GB    │   10 GB    │ 理论磁盘/内存最平衡                  │
# │  43  │  5.0%    │     26 M     │    1 GB    │    1 GB    │ 原方案                               │
# └──────┴──────────┴──────────────┴────────────┴────────────┴──────────────────────────────────────┘
#
# 理论值 vs 实际值：
# 表中「磁盘」「内存」是计算全部完成后的理论值。
# 但 puzzle135 预计需 ~6000 年，实际增长极慢：
#
# --- d=35 实际存储增长（双机 ~1,177 MK/s）---
# 每年新增 DP：~108 万个
# 每年 DP 数据增长：108 万 × 40 字节 ≈ 43 MB/年
# 每年 RAM 增长：108 万 × 48 字节 ≈ 52 MB/年
#
# ┌──────────┬────────────┬────────────┬────────────────────────┐
# │  时间    │ 累积 DP    │ work 文件  │ 合并时 RAM             │
# ├──────────┼────────────┼────────────┼────────────────────────┤
# │  1 年    │    108 万  │  ~265 MB   │  ~64 MB                │
# │  5 年    │    540 万  │  ~437 MB   │  ~272 MB               │
# │ 10 年    │  1,080 万  │  ~655 MB   │  ~531 MB               │
# │ 50 年    │  5,400 万  │  ~2.4 GB   │  ~2.6 GB               │
# └──────────┴────────────┴────────────┴────────────────────────┘
# （work 文件 = 220 MB 袋鼠状态 + 2 MB 桶开销 + DP 数据）
# （合并时 RAM = 12 MB 基础 + 48 × 累积 DP）
#
# 结论：d=35 在实际使用中存储极为宽裕，50 GB 预算可轻松支撑 50 年以上。
# 而开销仅 0.02%（对比 d=43 的 5%），最大限度利用每一次计算。
#
# --- DP 产出速率（d=35）---
# 每个 DP 平均间隔：2^35 ≈ 3.44 × 10^10 次跳跃
# Mac (576.79 MK/s)：59.6 秒/DP ≈ 1 分钟/DP，每天 ~1,451 个
# Win (600 MK/s)：   57.3 秒/DP ≈ 1 分钟/DP，每天 ~1,509 个
# 双机合计：每天 ~2,960 个 DP
# 每次 30 分钟保存间隔：Mac 累积 ~30 个新 DP（约 1.2 KB，可忽略）