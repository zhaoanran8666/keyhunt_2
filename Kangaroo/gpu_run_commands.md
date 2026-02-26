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
  -w /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135_test.work -wi 120 -ws -wt 15000 \
  -o /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135_result.txt \
  /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135.txt

# Puzzle 135重启续跑 2月25日 NB_RUN=1 提升7%，不影响续跑。
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
unset KANGAROO_METAL_STATE_CACHE_MODE KANGAROO_METAL_NO_STATE_CACHE KANGAROO_METAL_DISABLE_AUTO_MODE14
KANGAROO_METAL_AUTO_MODE14_WARMUP=1 KANGAROO_METAL_AUTO_MODE14_ITERS=2 KANGAROO_METAL_AUTO_MODE14_MIN_GAIN_PCT=0 \
KANGAROO_METAL_BLOCK_WAIT=1 KANGAROO_METAL_GRP_SIZE=128 KANGAROO_METAL_NB_RUN=1 KANGAROO_METAL_WAIT_TIMEOUT_MS=8000 \
./kangaroo -gpu -gpuId 0 -g 80,256 -t 0 \
  -i /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135_test.work \
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