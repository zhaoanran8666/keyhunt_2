# Kangaroo（SECP256K1 区间 ECDLP 求解器）

基于 Pollard's Kangaroo（袋鼠算法）的 SECP256K1 区间离散对数求解程序。
当前仓库已支持：

- CPU 求解
- NVIDIA CUDA 后端（Linux）
- Apple Metal 后端（macOS，`make gpu=1`）
- 可选对称优化构建（`make ... sym=1`）

本 README 按当前代码实现整理，重点覆盖 macOS + Metal GPU 的使用与调优。

## 1. 目录与可执行文件

在本仓库中，袋鼠算法位于：

- `/Users/zhaoanran/Desktop/keyhunt_2/Kangaroo`

编译后可执行文件：

- `/Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/kangaroo`

## 2. 编译

### 2.1 macOS（Apple Silicon / Intel + Metal）

依赖：

- Xcode Command Line Tools（提供 `clang++`、Metal Framework）
- `make`

编译命令：

```bash
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
make clean
make gpu=1 -j8
```

启用对称优化（推荐用于当前这版 Mac GPU 实现）：

```bash
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
make clean
make gpu=1 sym=1 -j8
```

说明：

- 在 Darwin 下 `gpu=1` 会自动走 Metal 后端（`GPUEngineMetal.mm` + `KangarooMetal.metal`）。
- `sym=1` 会额外开启 `-DUSE_SYMMETRY`，并改变 GPU 内部状态布局与步进逻辑。

### 2.2 Linux CPU

```bash
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
make clean
make -j
```

### 2.3 Linux CUDA

```bash
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
make clean
make gpu=1 ccap=86 -j
```

将 `ccap=86` 改为你的显卡算力版本（如 75/86/89 等）。

## 3. 输入文件格式

输入文件为纯文本，每行十六进制：

1. 起始范围（Start range）
2. 结束范围（End range）
3. 第 1 个目标公钥
4. 第 2 个目标公钥
5. ...

支持压缩和非压缩公钥。

示例（`/Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135.txt`）：

```text
4000000000000000000000000000000000
7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
02145D2611C823A396EF6712CE0F712F09B9B4F3135E3E0AA3230FB9B6D08D1E16
```

## 4. 快速开始

### 4.1 查看参数

```bash
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
./kangaroo -h
```

### 4.2 列出可用 GPU

```bash
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
./kangaroo -l
```

### 4.3 CPU 模式

```bash
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
./kangaroo -t 16 -o puzzle54_result.txt puzzle54.txt
```

### 4.4 macOS GPU（Metal）基础命令

```bash
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
./kangaroo -gpu -gpuId 0 -g 80,256 -d 46 -t 0 -o puzzle135_result.txt puzzle135.txt
```

参数说明：

- `-gpu`：开启 GPU
- `-gpuId 0`：使用第 0 张 GPU
- `-g 80,256`：网格参数 `X,Y`
- `-d 46`：DP 位数（distinguished points）
- `-t 0`：仅 GPU，不启用 CPU 线程

## 5. Workfile（断点续跑）

### 5.1 首次运行并周期保存

```bash
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
./kangaroo -gpu -gpuId 0 -g 80,256 -d 44 -t 0 \
  -w /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135.work -wi 60 -ws -wt 15000 \
  -o /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135_result.txt \
  /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135.txt
```

### 5.2 从 workfile 续跑

```bash
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
./kangaroo -gpu -gpuId 0 -g 80,256 -t 0 \
  -i /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135.work \
  -w /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135.work -wi 600 -ws -wt 15000 \
  -o /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135_result.txt \
  /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135.txt
```

### 5.3 查看/校验 workfile

```bash
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
./kangaroo -winfo /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135.work
./kangaroo -wcheck /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/puzzle135.work
```

### 5.4 合并工作文件

```bash
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
./kangaroo -wm save1.work save2.work save_merged.work
```

或合并目录：

```bash
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
./kangaroo -wmdir ./work_parts merged.work
```

## 6. macOS Metal 调优（重点）

### 6.1 推荐起步配置

```bash
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
unset KANGAROO_METAL_PROFILE KANGAROO_METAL_INV_PROFILE
KANGAROO_METAL_STATE_CACHE_MODE=1 \
KANGAROO_METAL_BLOCK_WAIT=1 \
KANGAROO_METAL_GRP_SIZE=64 \
KANGAROO_METAL_NB_RUN=4 \
KANGAROO_METAL_WAIT_TIMEOUT_MS=8000 \
./kangaroo -gpu -gpuId 0 -g 80,256 -d 46 -t 0 -o puzzle135_result.txt puzzle135.txt
```

### 6.2 自动模式（默认行为）

当你没有显式设置 `KANGAROO_METAL_STATE_CACHE_MODE` 且未禁用自动模式时，程序会在 mode 1 / mode 4 之间做基准选择。

可调参数：

- `KANGAROO_METAL_AUTO_MODE14_WARMUP`（默认 3）
- `KANGAROO_METAL_AUTO_MODE14_ITERS`（默认 5）
- `KANGAROO_METAL_AUTO_MODE14_MIN_GAIN_PCT`（默认 2）
- `KANGAROO_METAL_DISABLE_AUTO_MODE14=1`（禁用自动选择）

### 6.3 状态缓存模式（`KANGAROO_METAL_STATE_CACHE_MODE`）

- `0`：full
- `1`：none
- `2`：px
- `3`：d
- `4`：simd
- `5`：jacobian（当前对 symmetry 构建不兼容，会回退）

兼容旧变量：

- `KANGAROO_METAL_NO_STATE_CACHE`

### 6.4 关键环境变量（Metal）

- `KANGAROO_METAL_GRP_SIZE`
  - 默认 `16`，范围 `1..128`
- `KANGAROO_METAL_NB_RUN`
  - 默认 `4`，范围 `1..64`
- `KANGAROO_METAL_WAIT_TIMEOUT_MS`
  - 默认 `3000`，范围 `100..60000`
- `KANGAROO_METAL_BLOCK_WAIT`
  - 置 `1` 使用阻塞等待
- `KANGAROO_METAL_PROFILE`
  - 打印平均 kernel 时间 / MKey/s
- `KANGAROO_METAL_INV_PROFILE`
  - 打印逆元路径统计
- `KANGAROO_METAL_SHADER_PATH`
  - 指定 `.metal` 文件路径

可选 shader 实验开关：

- `KANGAROO_METAL_NATIVE_WIDE_MUL`
- `KANGAROO_METAL_UNSIGNED_MULHI`
- `KANGAROO_METAL_ENABLE_REDUCEC_SPECIAL`
- `KANGAROO_METAL_DISABLE_REDUCEC_SPECIAL`

### 6.5 自动扫参脚本

已内置：

- `/Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/scripts/metal_mode_sweep.sh`
- `/Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/scripts/metal_dp_sweep.sh`

示例：

```bash
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
scripts/metal_mode_sweep.sh puzzle135.txt 43 40
scripts/metal_dp_sweep.sh puzzle135.txt 43 47 40
```

## 7. `-check` 自检

CPU 自检：

```bash
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
./kangaroo -check
```

GPU 自检（包含 Metal 单元测试）：

```bash
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
./kangaroo -gpu -gpuId 0 -g 64,256 -check
```

## 8. 分布式（Server/Client）

### 8.1 启动服务端

```bash
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
./kangaroo -s -d 12 -w save.work -wi 300 -o result.txt in.txt
```

### 8.2 启动客户端

```bash
cd /Users/zhaoanran/Desktop/keyhunt_2/Kangaroo
./kangaroo -gpu -t 0 -c 127.0.0.1 -w kang.work -wi 600
```

注意：

- 服务端协议无认证，不建议直接暴露公网。
- 同一任务运行期尽量保持客户端数量稳定，避免 DP 开销模型失真。

## 9. 命令行参数（与当前代码一致）

```text
Kangaroo [-v] [-t nbThread] [-d dpBit] [gpu] [-check]
         [-gpuId gpuId1[,gpuId2,...]] [-g g1x,g1y[,g2x,g2y,...]]
         inFile
 -v: Print version
 -gpu: Enable gpu calculation
 -gpuId gpuId1,gpuId2,...: List of GPU(s) to use, default is 0
 -g g1x,g1y,g2x,g2y,...: Specify GPU(s) kernel gridsize
 -d: Specify number of leading zeros for the DP method (default is auto)
 -t nbThread: Secify number of thread
 -w workfile: Specify file to save work into (current processed key only)
 -i workfile: Specify file to load work from (current processed key only)
 -wi workInterval: Periodic interval (in seconds) for saving work
 -ws: Save kangaroos in the work file
 -wss: Save kangaroos via the server
 -wsplit: Split work file of server and reset hashtable
 -wm file1 file2 destfile: Merge work file
 -wmdir dir destfile: Merge directory of work files
 -wt timeout: Save work timeout in millisec (default is 3000ms)
 -winfo file1: Work file info file
 -wpartcreate name: Create empty partitioned work file (name is a directory)
 -wcheck worfile: Check workfile integrity
 -m maxStep: number of operations before give up the search
 -s: Start in server mode
 -c server_ip: Start in client mode and connect to server server_ip
 -sp port: Server port, default is 17403
 -nt timeout: Network timeout in millisec (default is 3000ms)
 -o fileName: output result to fileName
 -l: List available GPU devices
 -check: Check GPU kernel vs CPU
 inFile: intput configuration file
```

## 10. 说明与建议

- 这是区间离散对数求解工具，计算量与区间宽度强相关。
- `-d`、`-g`、`KANGAROO_METAL_GRP_SIZE`、`KANGAROO_METAL_NB_RUN` 会共同影响速度与内存。
- 建议先用短时间 sweep（模式 + DP）找本机最优参数，再长期运行。
- 长跑任务务必启用 `-w/-wi/-ws`，并在停机前确认最近一次 `SaveWork ... done` 已输出。

## 11. 许可证

本目录代码遵循 GPLv3（见 `/Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/LICENSE.txt`）。
