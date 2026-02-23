"""
Mempool 监控模块 — REST 客户端（备用数据源）

职责：
- 定期轮询 Blockstream API 检查 Puzzle 地址的交易活动
- 作为 WebSocket 的补充验证和容灾备份
- 检测地址余额变化

API 说明：
  基础 URL: https://blockstream.info/api
  地址交易: GET /address/{addr}/txs
  地址信息: GET /address/{addr}
"""

import asyncio
import logging
from typing import Callable, Dict, Optional, Set

import aiohttp

from . import config

logger = logging.getLogger(__name__)


class BlockstreamRestClient:
    """
    Blockstream REST API 客户端。

    通过定期轮询所有监控地址的交易状态，
    作为 WebSocket 实时推送的补充和验证。

    属性:
        addresses (set[str]): 监控的地址集合
        on_transaction (Callable): 发现新交易时的回调
        running (bool): 运行状态标志
        known_txids (set[str]): 已知交易 ID 集合（避免重复告警）
        address_chain_stats (dict): 地址的链上统计缓存
    """

    def __init__(self, addresses: Set[str], on_transaction: Callable):
        """
        参数:
            addresses: 要监控的地址集合
            on_transaction: 发现新交易时的回调，签名为 callback(tx_data: dict)
        """
        self.addresses = set(addresses)
        self.on_transaction = on_transaction
        self.running = False
        self.known_txids: Set[str] = set()
        self.address_chain_stats: Dict[str, Dict] = {}
        self._pending_baseline_addresses: Set[str] = set()

    async def start(self) -> None:
        """
        启动 REST 轮询循环。

        首轮扫描记录基线（已知交易），后续检测增量变化。
        """
        self.running = True
        logger.info("Blockstream REST 轮询已启动")

        # 首轮：建立基线，记录所有已知交易
        await self._full_scan(is_baseline=True)

        # 后续轮询：检测增量变化
        while self.running:
            await asyncio.sleep(config.REST_POLL_INTERVAL)
            if not self.running:
                break

            # 热重载新增地址需要先做基线，避免把历史交易当作新交易。
            pending_baseline = self._consume_pending_baseline_addresses()
            if pending_baseline:
                logger.info(
                    f"REST 为新增地址建立基线: {len(pending_baseline)} 个"
                )
                await self._full_scan(
                    is_baseline=True,
                    addresses=pending_baseline,
                )

            await self._full_scan(is_baseline=False)

    async def stop(self) -> None:
        """停止轮询。"""
        self.running = False
        logger.info("Blockstream REST 轮询已停止")

    def update_addresses(self, new_addresses: Set[str]) -> None:
        """
        更新监控地址列表。

        参数:
            new_addresses: 新的地址集合
        """
        normalized = set(new_addresses)
        added = normalized - self.addresses
        removed = self.addresses - normalized

        self.addresses = normalized
        self._pending_baseline_addresses -= removed
        self._pending_baseline_addresses |= added

        logger.info(
            f"REST 地址列表已更新，共 {len(self.addresses)} 个地址 "
            f"(+{len(added)}, -{len(removed)})"
        )

    def _consume_pending_baseline_addresses(self) -> Set[str]:
        """
        取出等待建立基线的新增地址集合。
        """
        pending = set(self._pending_baseline_addresses)
        self._pending_baseline_addresses.clear()
        return pending

    async def _full_scan(
        self,
        is_baseline: bool = False,
        addresses: Optional[Set[str]] = None,
    ) -> None:
        """
        扫描所有监控地址的交易活动。

        参数:
            is_baseline: True 表示首轮基线扫描（只记录，不告警）
            addresses: 可选，指定扫描子集；默认扫描当前全部地址
        """
        target_addresses = set(self.addresses if addresses is None else addresses)
        if not target_addresses:
            return

        scan_type = "基线扫描" if is_baseline else "增量扫描"
        logger.debug(f"开始{scan_type}，共 {len(target_addresses)} 个地址")

        async with aiohttp.ClientSession(
            timeout=aiohttp.ClientTimeout(total=config.REST_REQUEST_TIMEOUT)
        ) as session:
            for addr in target_addresses:
                if not self.running:
                    break
                try:
                    await self._check_address(session, addr, is_baseline)
                except Exception as e:
                    logger.error(f"检查地址 {addr} 时出错: {e}")

                # 请求间延迟，避免限流
                await asyncio.sleep(config.REST_REQUEST_DELAY)

        logger.debug(f"{scan_type}完成")

    async def _check_address(
        self, session: aiohttp.ClientSession,
        addr: str, is_baseline: bool
    ) -> None:
        """
        检查单个地址的交易活动。

        参数:
            session: aiohttp 会话
            addr: 比特币地址
            is_baseline: 是否为基线扫描
        """
        url = f"{config.BLOCKSTREAM_API_BASE}/address/{addr}/txs"

        async with session.get(url) as resp:
            if resp.status == 200:
                txs = await resp.json()
                for tx in txs:
                    txid = (tx.get("txid") or "").strip().lower()
                    if txid and txid not in self.known_txids:
                        self.known_txids.add(txid)
                        if not is_baseline:
                            # 非基线扫描发现新交易，触发回调
                            logger.info(
                                f"REST 发现新交易: {addr} - {txid[:16]}..."
                            )
                            try:
                                await self.on_transaction(tx)
                            except Exception as e:
                                logger.error(f"REST 交易回调出错: {e}")
            elif resp.status == 429:
                logger.warning("Blockstream API 限流，暂停请求")
                await asyncio.sleep(10)
            else:
                logger.warning(
                    f"Blockstream API 返回 {resp.status}: {addr}"
                )
