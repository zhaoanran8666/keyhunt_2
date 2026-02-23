"""
Mempool 监控模块 — 告警器

职责：
- 终端彩色高亮输出关键事件
- macOS 声音提示（可配置开关）
- 日志文件持久化记录

告警级别：
- CRITICAL: 检测到公钥暴露（某个 Puzzle 地址正在花费资金）
- WARNING:  检测到 Puzzle 地址有交易活动（但未提取到公钥）
- INFO:     连接状态变化、心跳等常规信息
"""

import asyncio
import logging
import os
import subprocess
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Optional

from . import config

logger = logging.getLogger(__name__)

# 上海时区 UTC+8
CST = timedelta(hours=8)

# ANSI 终端颜色代码
class Colors:
    RED = "\033[91m"
    GREEN = "\033[92m"
    YELLOW = "\033[93m"
    BLUE = "\033[94m"
    MAGENTA = "\033[95m"
    CYAN = "\033[96m"
    WHITE = "\033[97m"
    BOLD = "\033[1m"
    BLINK = "\033[5m"
    RESET = "\033[0m"


def _now_cst() -> str:
    """获取当前上海时间的格式化字符串。"""
    now = datetime.now(timezone(CST))
    return now.strftime("%Y-%m-%d %H:%M:%S CST")


def _play_sound(sound_file: str) -> None:
    """
    播放 macOS 系统声音（非阻塞）。

    参数:
        sound_file: .aiff 声音文件路径
    """
    if not config.ALERT_SOUND_ENABLED:
        return
    try:
        subprocess.Popen(
            ["afplay", sound_file],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception as e:
        logger.debug(f"播放声音失败: {e}")


class Alerter:
    """
    告警器 — 整合终端输出、声音提示和日志文件。

    属性:
        log_file (Path): 日志文件路径
        file_logger (logging.Logger): 文件日志记录器
    """

    def __init__(self):
        """初始化告警器，创建日志目录和文件日志。"""
        # 确保日志目录存在
        config.LOG_DIR.mkdir(parents=True, exist_ok=True)

        # 创建独立的文件日志记录器（不影响终端输出）
        self.log_file = config.LOG_DIR / "mempool_alerts.log"
        self.file_logger = logging.getLogger("mempool_alert_file")
        self.file_logger.setLevel(logging.DEBUG)

        # 避免重复添加 handler
        if not self.file_logger.handlers:
            fh = logging.FileHandler(self.log_file, encoding="utf-8")
            fh.setFormatter(
                logging.Formatter("%(asctime)s | %(levelname)s | %(message)s")
            )
            self.file_logger.addHandler(fh)

    def alert_pubkey_exposed(
        self, address: str, pubkey: str, txid: str,
        destinations: list, fee: int
    ) -> None:
        """
        紧急告警：公钥已暴露！某个 Puzzle 的私钥已被找到。

        参数:
            address: 被花费的 Puzzle 地址
            pubkey: 暴露的公钥十六进制字符串
            txid: 交易哈希
            destinations: 资金流向地址列表
            fee: 交易手续费（satoshis）
        """
        timestamp = _now_cst()

        # 终端紧急输出
        print(f"\n{'='*70}")
        print(f"{Colors.RED}{Colors.BOLD}{Colors.BLINK}"
              f"🚨🚨🚨 紧急告警：PUZZLE 私钥已被破解！ 🚨🚨🚨"
              f"{Colors.RESET}")
        print(f"{'='*70}")
        print(f"{Colors.YELLOW}时间:     {timestamp}{Colors.RESET}")
        print(f"{Colors.CYAN}地址:     {address}{Colors.RESET}")
        print(f"{Colors.RED}公钥:     {pubkey}{Colors.RESET}")
        print(f"{Colors.MAGENTA}交易ID:   {txid}{Colors.RESET}")
        print(f"{Colors.GREEN}手续费:   {fee} satoshis{Colors.RESET}")
        if destinations:
            print(f"{Colors.WHITE}资金流向:{Colors.RESET}")
            for dest in destinations:
                print(f"  → {dest}")
        print(f"{'='*70}\n")

        # 文件日志
        self.file_logger.critical(
            f"公钥暴露 | 地址={address} | 公钥={pubkey} | "
            f"交易={txid} | 手续费={fee}sat | "
            f"流向={','.join(destinations)}"
        )

        # 播放紧急告警音（连续播放3次）
        for _ in range(3):
            _play_sound(config.ALERT_URGENT_SOUND_FILE)

    def alert_address_activity(
        self, address: str, direction: str, txid: str
    ) -> None:
        """
        普通告警：检测到监控地址有交易活动。

        参数:
            address: 涉及的 Puzzle 地址
            direction: "spending" 或 "receiving"
            txid: 交易哈希
        """
        timestamp = _now_cst()

        direction_label = "花费" if direction == "spending" else "接收"
        color = Colors.RED if direction == "spending" else Colors.GREEN

        print(f"\n{color}{Colors.BOLD}"
              f"⚡ [{timestamp}] 地址活动: {address} 正在{direction_label}资金"
              f"{Colors.RESET}")
        print(f"  交易ID: {txid}")

        self.file_logger.warning(
            f"地址活动 | {direction_label} | 地址={address} | 交易={txid}"
        )

        _play_sound(config.ALERT_SOUND_FILE)

    def info(self, message: str) -> None:
        """
        信息级别输出。

        参数:
            message: 输出内容
        """
        timestamp = _now_cst()
        print(f"{Colors.CYAN}[{timestamp}] ℹ️  {message}{Colors.RESET}")
        self.file_logger.info(message)

    def status(self, message: str) -> None:
        """
        状态输出（不写入文件日志）。

        参数:
            message: 状态信息
        """
        timestamp = _now_cst()
        print(f"{Colors.BLUE}[{timestamp}] 📡 {message}{Colors.RESET}")

    def error(self, message: str) -> None:
        """
        错误输出。

        参数:
            message: 错误信息
        """
        timestamp = _now_cst()
        print(f"{Colors.RED}[{timestamp}] ❌ {message}{Colors.RESET}")
        self.file_logger.error(message)
