# BTC Puzzle Mempool Monitor

实时监听 BTC Puzzle 地址相关交易，发现公钥暴露后自动触发 Kangaroo 求解私钥，并立即进入自动广播与手续费竞价战流程。

## 端到端流程

1. `websocket_client.py` 订阅 mempool.space WebSocket（主数据源）。
2. `rest_client.py` 按间隔轮询 Blockstream（备用与补偿）。
3. `monitor.py` 去重交易、调用 `tx_parser.py` 解析方向/公钥。
4. 一旦检测到监控地址在花费且公钥可提取：
   - `puzzle_db.py` 查询该地址对应 Puzzle 编号与搜索区间。
   - `kangaroo_solver.py` 生成配置并启动 Kangaroo GPU 求解。
5. 求解到私钥后，`tx_broadcaster.py` 自动：
   - 构造并签名交易（转入 `SAFE_RECEIVE_ADDRESS`）。
   - 多端点广播（mempool.space / Blockstream / 可选 Slipstream）。
   - 持续监控竞争交易并执行 RBF 加价，直到确认或超时。

## 目录结构

```text
mempool_monitor/
├── __init__.py
├── address_loader.py        # 地址加载与热重载检测
├── alerter.py               # 告警输出、声音、日志
├── config.py                # 所有配置项
├── kangaroo_solver.py       # Kangaroo 调度、结果解析、回调
├── main.py                  # CLI 入口
├── monitor.py               # 主协调器（监控/求解/广播）
├── puzzle_db.py             # 地址 -> PuzzleInfo（含范围）
├── README.md
├── requirements.txt
├── rest_client.py           # Blockstream REST 备用轮询
├── tx_broadcaster.py        # 交易构造 + 广播 + 费率竞价战
├── tx_parser.py             # 交易解析与公钥提取
├── websocket_client.py      # mempool.space WS 实时推送
├── logs/
├── kangaroo_work/
└── tests/
    └── test_tx_broadcaster_fee_war.py
```

## 快速开始

```bash
cd /Users/zhaoanran/Desktop/keyhunt_2
conda activate anaconda
pip install -r mempool_monitor/requirements.txt
```

1. 编辑 `mempool_monitor/config.py`，至少配置：
   - `SAFE_RECEIVE_ADDRESS`（必须）
2. 确认 Kangaroo 可执行文件存在：
   - 默认路径：`/Users/zhaoanran/Desktop/keyhunt_2/Kangaroo/kangaroo`
3. 启动：

```bash
python -m mempool_monitor.main
```

仅使用 WebSocket（不启用 REST 备用轮询）：

```bash
python -m mempool_monitor.main --ws-only
```

使用自定义地址文件：

```bash
python -m mempool_monitor.main --address-file /path/to/addresses.txt
```

## 配置说明（`config.py`）

### 交易与竞价（核心）

| 配置项 | 说明 | 默认值 |
|---|---|---|
| `SAFE_RECEIVE_ADDRESS` | 截胡成功后 BTC 转入地址 | `""`（必须手动填写） |
| `TX_FEE_SAT_PER_VBYTE` | 无竞争者时初始保底费率 | `100` |
| `ENABLE_SLIPSTREAM` | 是否启用 MARA Slipstream 广播 | `False` |
| `FEE_MULTIPLIER` | 费率倍数（我方=对手最高费率×倍数） | `3` |
| `FEE_WAR_POLL_INTERVAL` | 竞价轮询间隔（秒） | `5` |
| `FEE_WAR_TIMEOUT` | 竞价战超时（秒） | `600` |

说明：当前策略不设置手续费上限，目标是始终保持我方费率高于竞争者；退出条件是“已确认”或“超时”。

### 数据源与轮询

| 配置项 | 说明 | 默认值 |
|---|---|---|
| `MEMPOOL_WS_URL` | WebSocket 主数据源 | `wss://mempool.space/api/v1/ws` |
| `WS_RECONNECT_INTERVAL` | WS 重连间隔（秒） | `5` |
| `WS_PING_INTERVAL` | WS 心跳间隔（秒） | `30` |
| `WS_BATCH_SIZE` | 每批订阅地址数 | `10` |
| `WS_BATCH_DELAY` | 批次订阅间隔（秒） | `1.0` |
| `BLOCKSTREAM_API_BASE` | REST 备用数据源 | `https://blockstream.info/api` |
| `REST_POLL_INTERVAL` | REST 轮询间隔（秒） | `60` |
| `REST_REQUEST_TIMEOUT` | REST 请求超时（秒） | `15` |
| `REST_REQUEST_DELAY` | REST 请求间隔（秒） | `0.5` |

### Kangaroo 与路径

| 配置项 | 说明 | 默认值 |
|---|---|---|
| `KANGAROO_BINARY` | Kangaroo 可执行文件 | `PROJECT_ROOT / "Kangaroo" / "kangaroo"` |
| `KANGAROO_WORK_DIR` | 配置/结果文件目录 | `mempool_monitor/kangaroo_work` |
| `PUZZLE_ADDRESS_FILE` | 监控地址文件 | `unsolved_puzzles.txt` |
| `LOG_DIR` | 告警日志目录 | `mempool_monitor/logs` |

## 手续费竞价战细节

`tx_broadcaster.py` 的竞价战策略：

1. 查询目标地址 mempool 交易，筛出“花费同一 outpoint”的竞争交易。
2. 初始费率：`max(对手最高费率 × FEE_MULTIPLIER, TX_FEE_SAT_PER_VBYTE)`。
3. 初次广播后循环：
   - 查询当前 TX 是否确认。
   - 若竞争者费率 `>=` 我方当前费率，则 RBF 重构并按新费率重发。
4. 循环直到确认或达到 `FEE_WAR_TIMEOUT`。

## 依赖

`requirements.txt`：

- `websockets>=12.0`
- `aiohttp>=3.9`
- `bit>=0.8`
- `pytest>=7.0`
- `pytest-asyncio>=0.23`

## 测试

运行手续费竞价战相关单测：

```bash
pytest -q /Users/zhaoanran/Desktop/keyhunt_2/mempool_monitor/tests/test_tx_broadcaster_fee_war.py
```

## 日志

默认日志路径：`/Users/zhaoanran/Desktop/keyhunt_2/mempool_monitor/logs/mempool_alerts.log`

示例：

```text
2026-02-23 03:00:12 | CRITICAL | 公钥暴露 | 地址=1xxx | 公钥=02xxx...
```
