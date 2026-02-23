"""
Mempool 监控模块 — 主协调器

职责：
- 整合 WebSocket 实时监控 + REST 定期轮询
- 统一交易处理流水线：接收 → 解析 → 告警
- 检测到公钥暴露后自动调度 Kangaroo 求解私钥
- 求解成功后自动构造交易并多节点广播
- 管理地址列表的热重载
- 协调多个异步任务的生命周期和错误恢复
"""

import asyncio
from collections import deque
import logging
from typing import Deque, Dict, Optional

from .address_loader import AddressWatcher
from .alerter import Alerter
from .kangaroo_solver import KangarooSolver, SolveResult
from .puzzle_db import PuzzleDatabase
from .rest_client import BlockstreamRestClient
from .tx_broadcaster import TransactionBroadcaster
from .tx_parser import ParsedTransaction, parse_transaction
from .websocket_client import MempoolWebSocketClient
from . import config

logger = logging.getLogger(__name__)

# 地址文件热重载检查间隔（秒）
ADDRESS_RELOAD_INTERVAL = 30
MAX_SEEN_TXIDS = 10000


class MempoolMonitor:
    """
    Mempool 监控主协调器。

    整合所有子模块，提供统一的启停接口。

    属性:
        address_watcher (AddressWatcher): 地址文件监控器
        puzzle_db (PuzzleDatabase): Puzzle 地址数据库
        alerter (Alerter): 告警器
        solver (KangarooSolver): Kangaroo 自动求解器
        broadcaster (TransactionBroadcaster): 交易广播器
        ws_client (MempoolWebSocketClient): WebSocket 客户端
        rest_client (BlockstreamRestClient): REST 客户端
        enable_rest (bool): 是否启用 REST 备用数据源
        seen_txids (set[str]): 已处理的交易 ID 去重集合
    """

    def __init__(self, enable_rest: bool = True):
        """
        参数:
            enable_rest: 是否启用 Blockstream REST 备用轮询，默认 True
        """
        self.enable_rest = enable_rest
        self.address_watcher = AddressWatcher()
        self.puzzle_db = PuzzleDatabase()
        self.alerter = Alerter()
        self.seen_txids: set = set()
        self.seen_txid_order: Deque[str] = deque()
        self._tasks: list[asyncio.Task] = []
        self._stop_event = asyncio.Event()

        # 初始化 Kangaroo 求解器
        self.solver = KangarooSolver(
            on_key_found=self._on_key_found,
        )

        # 初始化交易广播器
        self.broadcaster = TransactionBroadcaster()

        # 初始化 WebSocket 客户端
        self.ws_client = MempoolWebSocketClient(
            addresses=self.address_watcher.addresses,
            on_transaction=self._on_transaction,
        )

        # 初始化 REST 客户端
        self.rest_client = BlockstreamRestClient(
            addresses=self.address_watcher.addresses,
            on_transaction=self._on_transaction,
        )

    async def run(self) -> None:
        """
        启动监控，运行所有异步任务。

        包含：
        1. WebSocket 实时监控（主任务）
        2. REST 定期轮询（备用任务，可选）
        3. 地址文件热重载检查

        使用 Ctrl+C 优雅关闭。
        """
        self.alerter.info(
            f"Mempool 监控启动，加载了 "
            f"{len(self.address_watcher.addresses)} 个 Puzzle 地址"
        )
        self.alerter.info(
            f"Puzzle 数据库: {len(self.puzzle_db)} 条映射记录"
        )
        self.alerter.info(f"WebSocket 端点: {config.MEMPOOL_WS_URL}")
        if self.enable_rest:
            self.alerter.info(
                f"REST 备用轮询: {config.BLOCKSTREAM_API_BASE} "
                f"(间隔 {config.REST_POLL_INTERVAL}s)"
            )
        self.alerter.info(
            f"Kangaroo 路径: {config.KANGAROO_BINARY}"
        )
        if config.SAFE_RECEIVE_ADDRESS:
            self.alerter.info(
                f"安全接收地址: {config.SAFE_RECEIVE_ADDRESS}"
            )
        else:
            self.alerter.error(
                "⚠️ 安全接收地址未配置！自动交易广播将被禁用"
            )
        self.alerter.info(
            f"告警日志: {self.alerter.log_file}"
        )

        self._stop_event.clear()

        # 构建任务列表
        self._tasks = [
            asyncio.create_task(
                self.ws_client.start(), name="websocket"
            ),
            asyncio.create_task(
                self._address_reload_loop(), name="address_reload"
            ),
        ]

        if self.enable_rest:
            self._tasks.append(
                asyncio.create_task(
                    self.rest_client.start(), name="rest_poll"
                )
            )

        try:
            # 等待所有任务（任一异常退出则全部取消）
            done, pending = await asyncio.wait(
                self._tasks, return_when=asyncio.FIRST_EXCEPTION
            )

            # 检查是否有任务异常退出
            for task in done:
                if task.exception():
                    logger.error(
                        f"任务 {task.get_name()} 异常退出: "
                        f"{task.exception()}"
                    )

        except asyncio.CancelledError:
            pass
        finally:
            await self.shutdown()

    async def shutdown(self) -> None:
        """优雅关闭所有子模块。"""
        if self._stop_event.is_set():
            return

        self._stop_event.set()
        self.alerter.info("正在关闭 Mempool 监控...")
        await self.ws_client.stop()
        await self.rest_client.stop()
        await self.solver.stop()

        current = asyncio.current_task()
        pending = []
        for task in self._tasks:
            if task is current:
                continue
            if not task.done():
                task.cancel()
                pending.append(task)

        if pending:
            await asyncio.gather(*pending, return_exceptions=True)

        self._tasks = []
        self.alerter.info("Mempool 监控已关闭")

    def _normalize_txid(self, value: Optional[str]) -> str:
        """标准化 txid 字符串。"""
        if not value:
            return ""
        return str(value).strip().lower()

    def _remember_txid(self, txid: str) -> bool:
        """
        记录 txid 并执行有界去重缓存。

        返回:
            bool: True 表示首次出现，False 表示已处理过
        """
        if txid in self.seen_txids:
            return False

        self.seen_txids.add(txid)
        self.seen_txid_order.append(txid)

        while len(self.seen_txid_order) > MAX_SEEN_TXIDS:
            old_txid = self.seen_txid_order.popleft()
            self.seen_txids.discard(old_txid)

        return True

    async def _on_transaction(self, tx_data: Dict) -> None:
        """
        统一交易处理回调。

        WebSocket 和 REST 客户端发现新交易时都会调用此方法。
        流程：去重 → 解析 → 告警。

        参数:
            tx_data: 原始交易 JSON 数据
        """
        txid = self._normalize_txid(tx_data.get("txid"))
        if not txid:
            logger.debug("收到缺少 txid 的交易数据，已忽略")
            return

        # 去重：避免 WebSocket 和 REST 重复处理同一笔交易
        if not self._remember_txid(txid):
            return

        normalized_tx = dict(tx_data)
        normalized_tx["txid"] = txid

        # 解析交易
        results = parse_transaction(
            normalized_tx, self.address_watcher.addresses
        )

        # 触发告警 + 自动截胡流水线
        for parsed in results:
            if parsed.direction == "spending" and parsed.pubkey:
                # 🚨 最高优先级：公钥已暴露 → 启动截胡流水线
                self.alerter.alert_pubkey_exposed(
                    address=parsed.matched_address,
                    pubkey=parsed.pubkey,
                    txid=parsed.txid,
                    destinations=parsed.destination_addresses,
                    fee=parsed.fee,
                )
                # 异步启动 Kangaroo 求解（不阻塞监控主循环）
                asyncio.create_task(
                    self._start_snipe(parsed),
                    name=f"snipe_{parsed.matched_address[:8]}",
                )
            elif parsed.direction == "spending":
                # ⚠️ 地址在花费但未提取到公钥（可能是 P2SH/Taproot 等）
                self.alerter.alert_address_activity(
                    address=parsed.matched_address,
                    direction="spending",
                    txid=parsed.txid,
                )
            else:
                # 📥 地址在接收资金（相对不紧急）
                self.alerter.alert_address_activity(
                    address=parsed.matched_address,
                    direction="receiving",
                    txid=parsed.txid,
                )

    async def _start_snipe(self, parsed: ParsedTransaction) -> None:
        """
        截胡流水线：公钥暴露 → Kangaroo 求解 → 交易广播。

        参数:
            parsed: 解析后的交易数据（含暴露的公钥和地址）
        """
        if not config.SAFE_RECEIVE_ADDRESS:
            self.alerter.error(
                "安全接收地址未配置，跳过 Kangaroo 求解与自动广播"
            )
            return

        # 查找 Puzzle 信息
        puzzle_info = self.puzzle_db.get_by_address(parsed.matched_address)
        if not puzzle_info:
            self.alerter.error(
                f"地址 {parsed.matched_address} 未在 Puzzle 数据库中找到，"
                f"无法确定搜索范围"
            )
            return

        self.alerter.info(
            f"🎯 启动截胡流水线: Puzzle {puzzle_info.puzzle_number}"
            f" [{puzzle_info.range_start}..{puzzle_info.range_end}]"
        )

        # 启动 Kangaroo 求解
        result = await self.solver.solve(puzzle_info, parsed.pubkey)

        if not result:
            self.alerter.error(
                f"Kangaroo 未能求解 Puzzle {puzzle_info.puzzle_number}"
            )
            return

        self.alerter.info(
            f"🔑 私钥已求解！Puzzle {puzzle_info.puzzle_number}: "
            f"0x{result.private_key[:16]}..."
        )

    async def _on_key_found(self, result: SolveResult) -> None:
        """
        Kangaroo 找到私钥后的回调：自动构造交易并广播。

        参数:
            result: 求解结果
        """
        self.alerter.info(
            f"💰 开始自动交易广播 — Puzzle {result.puzzle_info.puzzle_number}"
        )

        success = await self.broadcaster.execute(result)

        if success:
            self.alerter.info(
                f"✅ 交易广播成功！Puzzle {result.puzzle_info.puzzle_number}"
            )
        else:
            self.alerter.error(
                f"❌ 交易广播失败！Puzzle {result.puzzle_info.puzzle_number}\n"
                f"   私钥: 0x{result.private_key}\n"
                f"   请手动处理！"
            )

    async def _address_reload_loop(self) -> None:
        """
        定期检查地址文件变化并热重载。

        当 unsolved_puzzles.txt 被修改时，
        自动重新加载地址列表并更新各客户端。
        """
        try:
            while not self._stop_event.is_set():
                try:
                    await asyncio.wait_for(
                        self._stop_event.wait(),
                        timeout=ADDRESS_RELOAD_INTERVAL,
                    )
                    break
                except asyncio.TimeoutError:
                    pass

                if self.address_watcher.check_and_reload():
                    new_addrs = self.address_watcher.addresses
                    self.ws_client.update_addresses(new_addrs)
                    self.rest_client.update_addresses(new_addrs)
                    # 同步更新 Puzzle 数据库
                    self.puzzle_db = PuzzleDatabase()
                    self.alerter.info(
                        f"地址列表已热重载，当前 {len(new_addrs)} 个地址"
                    )
        except asyncio.CancelledError:
            return
