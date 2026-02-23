"""
Mempool 监控模块 — CLI 入口

用法：
    # 启动完整监控（WebSocket + REST 轮询）
    python -m mempool_monitor.main

    # 仅 WebSocket 模式（不启用 REST 轮询）
    python -m mempool_monitor.main --ws-only

    # 指定自定义地址文件
    python -m mempool_monitor.main --address-file /path/to/addresses.txt
"""

import argparse
import asyncio
import logging
import signal
import sys
from pathlib import Path

from . import config
from .monitor import MempoolMonitor


def setup_logging() -> None:
    """配置全局日志格式。"""
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
        datefmt="%H:%M:%S",
    )
    # 降低第三方库的日志级别
    logging.getLogger("websockets").setLevel(logging.WARNING)
    logging.getLogger("aiohttp").setLevel(logging.WARNING)


def parse_args() -> argparse.Namespace:
    """
    解析命令行参数。

    返回:
        argparse.Namespace: 解析后的参数对象
            --ws-only: 仅使用 WebSocket，不启用 REST 轮询
            --address-file: 自定义地址文件路径
    """
    parser = argparse.ArgumentParser(
        description="BTC Puzzle Mempool 实时监控",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  python -m mempool_monitor.main                   # 完整模式
  python -m mempool_monitor.main --ws-only          # 仅 WebSocket
  python -m mempool_monitor.main --address-file custom.txt
        """,
    )
    parser.add_argument(
        "--ws-only",
        action="store_true",
        help="仅使用 WebSocket 实时监控，不启用 Blockstream REST 轮询",
    )
    parser.add_argument(
        "--address-file",
        type=str,
        default=None,
        help="指定自定义的 Puzzle 地址文件路径",
    )
    return parser.parse_args()


def main() -> None:
    """程序入口。"""
    args = parse_args()
    setup_logging()

    # 覆盖配置
    if args.address_file:
        config.PUZZLE_ADDRESS_FILE = Path(args.address_file)

    # 创建监控器
    monitor = MempoolMonitor(enable_rest=not args.ws_only)

    # 注册 SIGINT/SIGTERM 信号处理（优雅关闭）
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)

    def _signal_handler():
        print("\n收到退出信号，正在关闭...")
        loop.create_task(monitor.shutdown())

    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, _signal_handler)

    try:
        loop.run_until_complete(monitor.run())
    except KeyboardInterrupt:
        loop.run_until_complete(monitor.shutdown())
    finally:
        loop.close()


if __name__ == "__main__":
    main()
