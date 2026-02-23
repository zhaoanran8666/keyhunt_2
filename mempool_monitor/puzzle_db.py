"""
Mempool 监控模块 — Puzzle 地址数据库

职责：
- 维护"地址 → Puzzle 编号 → 搜索范围"的结构化映射
- 从 unsolved_puzzles.txt 的注释中自动解析 Puzzle 编号
- 计算每个 Puzzle 的搜索范围: [2^(N-1), 2^N - 1]

数据来源:
  unsolved_puzzles.txt 中的注释行格式如:
  # === Puzzle 76-79 ===
  后面跟着 4 个地址，依次对应 Puzzle 76, 77, 78, 79
"""

import logging
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Optional

from . import config

logger = logging.getLogger(__name__)


@dataclass
class PuzzleInfo:
    """
    单个 Puzzle 的完整信息。

    属性:
        puzzle_number (int): Puzzle 编号（如 66, 130 等）
        address (str): 对应的比特币地址
        range_start (str): 搜索范围起始值（十六进制，无 0x 前缀）
        range_end (str): 搜索范围结束值（十六进制，无 0x 前缀）
    """
    puzzle_number: int
    address: str
    range_start: str  # 十六进制，如 "20000000000000000"
    range_end: str    # 十六进制，如 "3FFFFFFFFFFFFFFFF"

    def bit_length(self) -> int:
        """返回 Puzzle 的位长度。"""
        return self.puzzle_number


def compute_range(puzzle_number: int) -> tuple:
    """
    计算 Puzzle N 的私钥搜索范围。

    范围: [2^(N-1), 2^N - 1]
    例如 Puzzle 66: [0x20000000000000000, 0x3FFFFFFFFFFFFFFFF]

    参数:
        puzzle_number: Puzzle 编号

    返回:
        tuple[str, str]: (range_start, range_end) 十六进制字符串，无 0x 前缀
    """
    start = 1 << (puzzle_number - 1)       # 2^(N-1)
    end = (1 << puzzle_number) - 1          # 2^N - 1
    return format(start, 'X'), format(end, 'X')


def build_puzzle_db(filepath: Path = None) -> Dict[str, PuzzleInfo]:
    """
    从 unsolved_puzzles.txt 构建地址 → PuzzleInfo 的映射数据库。

    解析逻辑：
    1. 读取注释行 "# === Puzzle 76-79 ===" 提取编号范围
    2. 后续非注释、非空行为该范围内的地址，按序分配编号
    3. 跳过"当前矿池活跃谜题"等特殊注释

    参数:
        filepath: 地址文件路径，默认使用 config.PUZZLE_ADDRESS_FILE

    返回:
        dict[str, PuzzleInfo]: 地址 → Puzzle 信息的映射
    """
    if filepath is None:
        filepath = config.PUZZLE_ADDRESS_FILE

    filepath = Path(filepath)
    if not filepath.exists():
        logger.error(f"地址文件不存在: {filepath}")
        return {}

    db: Dict[str, PuzzleInfo] = {}

    # 正则匹配注释中的编号范围：
    # "# === Puzzle 76-79 ===" 或 "# === 当前矿池活跃谜题 (71-74) ==="
    range_pattern = re.compile(
        r'#\s*===.*?(\d+)\s*[-~]\s*(\d+).*?==='
    )
    current_start = None
    current_end = None
    current_idx = 0

    with open(filepath, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()

            if not line:
                continue

            if line.startswith('#'):
                # 尝试匹配编号范围
                match = range_pattern.search(line)
                if match:
                    # 切换分组前检查上一组地址数量是否完整
                    if current_start is not None:
                        expected = current_end - current_start + 1
                        if current_idx < expected:
                            logger.warning(
                                f"Puzzle 分组 {current_start}-{current_end} "
                                f"地址数量不足: 实际 {current_idx} / 期望 {expected}"
                            )

                    current_start = int(match.group(1))
                    current_end = int(match.group(2))
                    current_idx = 0
                    logger.debug(
                        f"检测到分组: Puzzle {current_start}-{current_end}"
                    )
                continue

            # 非注释行 = 地址行
            if current_start is None:
                continue

            puzzle_num = current_start + current_idx
            if puzzle_num > current_end:
                # 超出当前分组范围，跳过
                logger.warning(
                    f"地址 {line} 超出分组范围 {current_start}-{current_end}"
                )
                continue

            # 计算搜索范围
            range_start, range_end = compute_range(puzzle_num)

            info = PuzzleInfo(
                puzzle_number=puzzle_num,
                address=line,
                range_start=range_start,
                range_end=range_end,
            )
            db[line] = info
            current_idx += 1

    # 文件结束时检查最后一组是否完整
    if current_start is not None:
        expected = current_end - current_start + 1
        if current_idx < expected:
            logger.warning(
                f"Puzzle 分组 {current_start}-{current_end} "
                f"地址数量不足: 实际 {current_idx} / 期望 {expected}"
            )

    logger.info(f"Puzzle 数据库构建完成，共 {len(db)} 条记录")
    return db


class PuzzleDatabase:
    """
    Puzzle 数据库封装类。

    提供地址查询和 Puzzle 编号查询接口。

    属性:
        db (dict[str, PuzzleInfo]): 地址 → Puzzle 信息的映射
    """

    def __init__(self, filepath: Path = None):
        """
        参数:
            filepath: 地址文件路径
        """
        self.db = build_puzzle_db(filepath)

    def get_by_address(self, address: str) -> Optional[PuzzleInfo]:
        """
        按地址查询 Puzzle 信息。

        参数:
            address: 比特币地址

        返回:
            PuzzleInfo | None
        """
        return self.db.get(address)

    def get_by_number(self, puzzle_number: int) -> Optional[PuzzleInfo]:
        """
        按 Puzzle 编号查询。

        参数:
            puzzle_number: Puzzle 编号

        返回:
            PuzzleInfo | None
        """
        for info in self.db.values():
            if info.puzzle_number == puzzle_number:
                return info
        return None

    def __len__(self) -> int:
        return len(self.db)

    def __contains__(self, address: str) -> bool:
        return address in self.db
