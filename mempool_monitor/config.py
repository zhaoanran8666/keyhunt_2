"""
Mempool 监控模块 — 配置文件

集中管理所有配置项：API 端点、文件路径、轮询间隔、告警设置等。
"""

import os
from pathlib import Path

# ============================================================
# 项目路径
# ============================================================

# 项目根目录（keyhunt_2/）
PROJECT_ROOT = Path(__file__).parent.parent

# Puzzle 地址列表文件路径
PUZZLE_ADDRESS_FILE = PROJECT_ROOT / "unsolved_puzzles.txt"

# 日志输出目录
LOG_DIR = Path(__file__).parent / "logs"

# ============================================================
# mempool.space WebSocket API（主数据源）
# ============================================================

MEMPOOL_WS_URL = "wss://mempool.space/api/v1/ws"

# WebSocket 重连间隔（秒）
WS_RECONNECT_INTERVAL = 5

# WebSocket 心跳间隔（秒）— 防止连接被服务端断开
WS_PING_INTERVAL = 30

# 每批订阅的地址数量（避免触发服务端限流）
WS_BATCH_SIZE = 10

# 批次间订阅间隔（秒）
WS_BATCH_DELAY = 1.0

# ============================================================
# Blockstream REST API（备用数据源）
# ============================================================

BLOCKSTREAM_API_BASE = "https://blockstream.info/api"

# REST 轮询间隔（秒）— 每轮完整扫描所有地址的间隔
REST_POLL_INTERVAL = 60

# 单个请求超时（秒）
REST_REQUEST_TIMEOUT = 15

# 请求间隔（秒）— 避免触发 Blockstream 限流
REST_REQUEST_DELAY = 0.5

# ============================================================
# 告警设置
# ============================================================

# 是否启用 macOS 声音告警
ALERT_SOUND_ENABLED = True

# macOS 系统告警音文件（可替换为其他 .aiff 文件）
ALERT_SOUND_FILE = "/System/Library/Sounds/Glass.aiff"

# 紧急告警音（发现交易时使用）
ALERT_URGENT_SOUND_FILE = "/System/Library/Sounds/Sosumi.aiff"

# ============================================================
# Kangaroo 求解器设置
# ============================================================

# Kangaroo 可执行文件路径
KANGAROO_BINARY = PROJECT_ROOT / "Kangaroo" / "kangaroo"

# Kangaroo 工作目录（配置文件和结果文件存放处）
KANGAROO_WORK_DIR = Path(__file__).parent / "kangaroo_work"

# ============================================================
# 交易构造与广播设置
# ============================================================

# ⚠️ 安全接收地址 — 截胡成功后 BTC 转入此地址
# 【重要】请在实际使用前替换为你自己的安全地址！
SAFE_RECEIVE_ADDRESS = ""

# 初始手续费率（satoshis/vByte）— 无竞争者时的初始保底费率
TX_FEE_SAT_PER_VBYTE = 100

# 是否启用 MARA Slipstream 私有广播
ENABLE_SLIPSTREAM = False

# ============================================================
# 手续费竞价战设置
# 策略: 不设加价上限，唯一目的是确保我们的手续费始终最高
# ============================================================

# 相对竞争者费率的倍数 — 我们的费率 = 竞争者最高费率 × 倍数
FEE_MULTIPLIER = 3

# 竞价战轮询间隔（秒）— 检查 mempool 中竞争交易的频率
FEE_WAR_POLL_INTERVAL = 5

# 竞价战超时时间（秒）— 超时后停止竞价（默认 10 分钟 = 约一个区块）
FEE_WAR_TIMEOUT = 600
