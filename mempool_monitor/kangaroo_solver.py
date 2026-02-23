"""
Mempool 监控模块 — Kangaroo 自动调度器

职责：
- 检测到公钥暴露后，自动生成 Kangaroo 配置文件
- 启动 Kangaroo GPU 子进程求解私钥
- 实时监控结果文件，解析提取私钥
- 找到私钥后触发交易构造回调

Kangaroo 配置文件格式（3行）：
  搜索范围起始值（十六进制，无 0x 前缀）
  搜索范围结束值（十六进制，无 0x 前缀）
  目标压缩公钥（十六进制，无 0x 前缀）

Kangaroo 结果输出格式：
  Key# 0 [1S]Pub:  0x03xxxx...
         Priv: 0x<私钥十六进制>
"""

import asyncio
import logging
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional

from . import config
from .puzzle_db import PuzzleInfo

logger = logging.getLogger(__name__)

# 从 Kangaroo 输出中提取私钥的正则表达式
PRIVKEY_PATTERN = re.compile(r'Priv:\s*0x([0-9A-Fa-f]+)')
HEX_PATTERN = re.compile(r"^[0-9A-Fa-f]+$")


@dataclass
class SolveResult:
    """
    Kangaroo 求解结果。

    属性:
        private_key (str): 私钥十六进制字符串（无 0x 前缀）
        public_key (str): 对应的压缩公钥
        puzzle_info (PuzzleInfo): Puzzle 信息
    """
    private_key: str
    public_key: str
    puzzle_info: PuzzleInfo


class KangarooSolver:
    """
    Kangaroo 算法自动调度器。

    当 Mempool 监控检测到公钥暴露后，自动：
    1. 生成 Kangaroo 配置文件
    2. 启动 GPU 子进程求解
    3. 监控结果文件
    4. 提取私钥后触发回调

    属性:
        kangaroo_binary (Path): Kangaroo 可执行文件路径
        work_dir (Path): 工作目录（配置文件和结果文件存放处）
        on_key_found (Callable): 找到私钥后的回调
        process: 当前运行的 Kangaroo 子进程
    """

    def __init__(self, on_key_found: Callable = None):
        """
        参数:
            on_key_found: 回调函数，签名为 callback(result: SolveResult)
        """
        self.kangaroo_binary = config.KANGAROO_BINARY
        self.work_dir = config.KANGAROO_WORK_DIR
        self.on_key_found = on_key_found
        self.process = None
        self._solve_lock = asyncio.Lock()

        # 确保工作目录存在
        self.work_dir.mkdir(parents=True, exist_ok=True)

    def _normalize_pubkey(self, pubkey: str) -> str:
        """
        规范化公钥格式，保证输出为压缩公钥（02/03 + 32字节X坐标）。

        支持输入:
        - 压缩公钥: 66 hex
        - 非压缩公钥: 130 hex（04 + X + Y）
        """
        clean = pubkey.strip()
        if clean.lower().startswith("0x"):
            clean = clean[2:]
        clean = clean.lower()

        if not clean or not HEX_PATTERN.fullmatch(clean):
            raise ValueError("公钥包含非十六进制字符")

        if len(clean) == 66 and clean[:2] in ("02", "03"):
            return clean.upper()

        if len(clean) == 130 and clean.startswith("04"):
            x = clean[2:66]
            y = clean[66:130]
            y_last_nibble = int(y[-1], 16)
            prefix = "02" if (y_last_nibble % 2 == 0) else "03"
            compressed = f"{prefix}{x}".upper()
            logger.info("检测到非压缩公钥，已转换为压缩格式供 Kangaroo 使用")
            return compressed

        raise ValueError(
            f"不支持的公钥格式，长度={len(clean)}，前缀={clean[:2]}"
        )

    def generate_config(
        self, puzzle_info: PuzzleInfo, pubkey: str
    ) -> Path:
        """
        生成 Kangaroo 配置文件。

        参数:
            puzzle_info: Puzzle 信息（含搜索范围）
            pubkey: 暴露的压缩公钥（十六进制，可能带或不带 0x 前缀）

        返回:
            Path: 生成的配置文件路径
        """
        clean_pubkey = self._normalize_pubkey(pubkey)

        config_path = self.work_dir / f"puzzle{puzzle_info.puzzle_number}_snipe.txt"

        content = (
            f"{puzzle_info.range_start}\n"
            f"{puzzle_info.range_end}\n"
            f"{clean_pubkey}\n"
        )

        with open(config_path, 'w') as f:
            f.write(content)

        logger.info(
            f"Kangaroo 配置文件已生成: {config_path}\n"
            f"  范围: [{puzzle_info.range_start}, {puzzle_info.range_end}]\n"
            f"  公钥: {clean_pubkey[:20]}..."
        )
        return config_path

    async def solve(
        self, puzzle_info: PuzzleInfo, pubkey: str
    ) -> Optional[SolveResult]:
        """
        启动 Kangaroo 求解私钥（异步）。

        完整流程：生成配置 → 启动子进程 → 监控输出 → 提取私钥。

        参数:
            puzzle_info: Puzzle 信息
            pubkey: 暴露的压缩公钥

        返回:
            SolveResult | None: 找到私钥则返回结果，超时或失败返回 None
        """
        async with self._solve_lock:
            # 先标准化公钥，避免把非压缩公钥直接喂给 Kangaroo。
            try:
                normalized_pubkey = self._normalize_pubkey(pubkey)
            except ValueError as e:
                logger.error(f"公钥格式错误，无法启动 Kangaroo: {e}")
                return None

            # 生成配置文件
            config_path = self.generate_config(
                puzzle_info, normalized_pubkey
            )

            # 结果输出文件
            result_path = self.work_dir / f"puzzle{puzzle_info.puzzle_number}_snipe_result.txt"

            # 清理旧结果
            if result_path.exists():
                result_path.unlink()

            # 构造命令行
            cmd = [
                str(self.kangaroo_binary),
                "-gpu",                       # 启用 GPU 加速
                "-o", str(result_path),       # 输出文件
                str(config_path),             # 配置文件
            ]

            logger.info(
                f"启动 Kangaroo 求解 Puzzle {puzzle_info.puzzle_number}...\n"
                f"  命令: {' '.join(cmd)}"
            )

            process = None
            try:
                # 启动子进程
                process = await asyncio.create_subprocess_exec(
                    *cmd,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.STDOUT,
                    cwd=str(self.kangaroo_binary.parent),
                )
                self.process = process

                # 同时监控子进程输出和结果文件
                return await self._monitor_solve(
                    process=process,
                    puzzle_info=puzzle_info,
                    pubkey=normalized_pubkey,
                    result_path=result_path,
                )

            except FileNotFoundError:
                logger.error(
                    f"Kangaroo 可执行文件不存在: {self.kangaroo_binary}"
                )
                return None
            except Exception as e:
                logger.error(f"Kangaroo 求解异常: {e}")
                return None
            finally:
                await self._cleanup_process(process)
                if self.process is process:
                    self.process = None

    async def _monitor_solve(
        self,
        process: asyncio.subprocess.Process,
        puzzle_info: PuzzleInfo,
        pubkey: str,
        result_path: Path,
    ) -> Optional[SolveResult]:
        """
        监控 Kangaroo 子进程的输出和结果文件。

        同时从两个渠道检测私钥：
        1. 子进程的 stdout 实时输出
        2. 结果文件的内容

        参数:
            puzzle_info: Puzzle 信息
            pubkey: 目标公钥
            result_path: 结果输出文件路径

        返回:
            SolveResult | None
        """
        found_key = None

        while process and process.returncode is None:
            # 读取子进程输出（非阻塞）
            try:
                line = await asyncio.wait_for(
                    process.stdout.readline(), timeout=2.0
                )
                if line:
                    decoded = line.decode('utf-8', errors='replace').strip()
                    if decoded:
                        logger.debug(f"[Kangaroo] {decoded}")

                    # 从输出中检测私钥
                    match = PRIVKEY_PATTERN.search(decoded)
                    if match:
                        found_key = match.group(1)
                        logger.info(
                            f"🎯 从 stdout 检测到私钥: 0x{found_key}"
                        )
                        break

            except asyncio.TimeoutError:
                pass

            # 同时检查结果文件
            if result_path.exists():
                file_key = self._parse_result_file(result_path)
                if file_key:
                    found_key = file_key
                    logger.info(
                        f"🎯 从结果文件检测到私钥: 0x{found_key}"
                    )
                    break

            # 检查进程是否已退出
            if process.returncode is not None:
                break

        # 进程结束后最后检查一次结果文件
        if not found_key and result_path.exists():
            found_key = self._parse_result_file(result_path)

        if found_key:
            result = SolveResult(
                private_key=found_key,
                public_key=pubkey,
                puzzle_info=puzzle_info,
            )
            # 触发回调
            if self.on_key_found:
                await self.on_key_found(result)
            return result

        logger.warning(
            f"Kangaroo 未能找到 Puzzle {puzzle_info.puzzle_number} 的私钥"
        )
        return None

    def _parse_result_file(self, result_path: Path) -> Optional[str]:
        """
        解析 Kangaroo 结果文件，提取私钥。

        结果文件格式示例：
            Key# 0 [1S]Pub:  0x034AF4B8...
                   Priv: 0x236FB6D5AD1F43

        参数:
            result_path: 结果文件路径

        返回:
            str | None: 私钥十六进制字符串（无 0x 前缀），未找到返回 None
        """
        try:
            with open(result_path, 'r') as f:
                content = f.read()

            match = PRIVKEY_PATTERN.search(content)
            if match:
                return match.group(1)
        except Exception as e:
            logger.debug(f"读取结果文件出错: {e}")

        return None

    async def stop(self) -> None:
        """停止正在运行的 Kangaroo 进程。"""
        await self._cleanup_process(self.process)
        self.process = None

    async def _cleanup_process(
        self, process: Optional[asyncio.subprocess.Process]
    ) -> None:
        """清理子进程资源。"""
        if process and process.returncode is None:
            try:
                process.terminate()
                await asyncio.wait_for(
                    process.wait(), timeout=5.0
                )
            except asyncio.TimeoutError:
                process.kill()
                await process.wait()
            logger.info("Kangaroo 子进程已终止")
