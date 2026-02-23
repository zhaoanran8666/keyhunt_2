"""
Mempool 监控模块 — 地址加载器

职责：
- 从 unsolved_puzzles.txt 解析 Puzzle 地址列表
- 跳过注释行（以 # 开头）和空行
- 支持热重载（监控文件变化自动刷新）

输入：文件路径（默认取 config.PUZZLE_ADDRESS_FILE）
输出：set[str] — 地址集合
"""

import logging
import os
from pathlib import Path
from typing import Set

from . import config

logger = logging.getLogger(__name__)


def load_addresses(filepath: Path = None) -> Set[str]:
    """
    从文件中加载 Puzzle 地址列表。

    参数:
        filepath: 地址文件路径，默认使用 config.PUZZLE_ADDRESS_FILE

    返回:
        set[str]: 去重后的地址集合

    异常:
        FileNotFoundError: 文件不存在时抛出
    """
    if filepath is None:
        filepath = config.PUZZLE_ADDRESS_FILE

    filepath = Path(filepath)
    if not filepath.exists():
        raise FileNotFoundError(f"地址文件不存在: {filepath}")

    addresses = set()
    with open(filepath, "r", encoding="utf-8") as f:
        for line_num, line in enumerate(f, 1):
            line = line.strip()

            # 跳过空行和注释行
            if not line or line.startswith("#"):
                continue

            # 基本格式验证：比特币地址以 1 或 3 或 bc1 开头
            if line.startswith(("1", "3", "bc1")):
                addresses.add(line)
            else:
                logger.warning(f"第 {line_num} 行格式异常，已跳过: {line}")

    logger.info(f"从 {filepath.name} 加载了 {len(addresses)} 个 Puzzle 地址")
    return addresses


class AddressWatcher:
    """
    地址文件监控器 — 支持热重载。

    通过比较文件修改时间戳来检测变化，
    当文件被修改时自动重新加载地址列表。

    属性:
        filepath (Path): 监控的文件路径
        addresses (set[str]): 当前加载的地址集合
        last_mtime (float): 上次文件修改时间戳
    """

    def __init__(self, filepath: Path = None):
        """
        参数:
            filepath: 地址文件路径，默认使用 config.PUZZLE_ADDRESS_FILE
        """
        self.filepath = Path(filepath) if filepath else config.PUZZLE_ADDRESS_FILE
        self.addresses: Set[str] = set()
        self.last_mtime: float = 0.0
        self.reload()

    def reload(self) -> Set[str]:
        """
        强制重新加载地址列表。

        返回:
            set[str]: 重新加载后的地址集合
        """
        self.addresses = load_addresses(self.filepath)
        self.last_mtime = os.path.getmtime(self.filepath)
        return self.addresses

    def check_and_reload(self) -> bool:
        """
        检查文件是否被修改，如是则自动重载。

        返回:
            bool: True 表示发生了重载，False 表示无变化
        """
        try:
            current_mtime = os.path.getmtime(self.filepath)
        except OSError as e:
            logger.error(f"检查地址文件时出错: {e}")
            return False

        if current_mtime <= self.last_mtime:
            return False

        old_count = len(self.addresses)
        try:
            self.reload()
        except Exception as e:
            # 地址文件在原子替换/编辑过程中可能短暂不可读，避免中断主监控流程。
            logger.error(f"地址文件变更后重载失败: {e}")
            return False

        new_count = len(self.addresses)
        logger.info(
            f"地址文件已更新，重新加载: {old_count} → {new_count} 个地址"
        )
        return True
