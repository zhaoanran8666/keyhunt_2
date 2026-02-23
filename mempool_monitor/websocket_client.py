"""
Mempool 监控模块 — WebSocket 客户端（主数据源）

职责：
- 连接 mempool.space WebSocket API
- 分批订阅 Puzzle 地址的 track-address
- 接收实时推送的交易数据
- 自动重连和心跳保活

API 说明：
  端点: wss://mempool.space/api/v1/ws
  订阅: 发送 {"track-address": "<地址>"} 即可订阅该地址的交易推送
  推送: 收到 {"address-transactions": {...}} 格式的实时交易通知
"""

import asyncio
import json
import logging
from typing import Callable, Optional, Set

import websockets
from websockets.exceptions import (
    ConnectionClosed,
    ConnectionClosedError,
    ConnectionClosedOK,
)

from . import config

logger = logging.getLogger(__name__)


class MempoolWebSocketClient:
    """
    mempool.space WebSocket 客户端。

    通过长连接实时接收监控地址的交易推送，
    支持自动重连、分批订阅和心跳保活。

    属性:
        addresses (set[str]): 当前订阅的地址集合
        on_transaction (Callable): 收到交易时的回调函数
        ws: WebSocket 连接对象
        running (bool): 运行状态标志
        subscribed_count (int): 已成功订阅的地址数量
    """

    def __init__(self, addresses: Set[str], on_transaction: Callable):
        """
        参数:
            addresses: 要监控的地址集合
            on_transaction: 收到交易数据时的回调，签名为 callback(tx_data: dict)
        """
        self.addresses = addresses
        self.on_transaction = on_transaction
        self.ws = None
        self.running = False
        self.subscribed_count = 0
        self._reconnect_requested = False

    async def start(self) -> None:
        """
        启动 WebSocket 客户端，包含自动重连逻辑。

        此方法会一直运行，直到 self.running 被设置为 False。
        连接断开时自动重连。
        """
        self.running = True
        while self.running:
            try:
                await self._connect_and_listen()
            except (ConnectionClosed, ConnectionClosedError, OSError) as e:
                if not self.running:
                    break
                logger.warning(
                    f"WebSocket 连接断开: {e}，"
                    f"{config.WS_RECONNECT_INTERVAL}秒后重连..."
                )
                await asyncio.sleep(config.WS_RECONNECT_INTERVAL)
            except Exception as e:
                if not self.running:
                    break
                logger.error(
                    f"WebSocket 意外错误: {e}，"
                    f"{config.WS_RECONNECT_INTERVAL}秒后重连..."
                )
                await asyncio.sleep(config.WS_RECONNECT_INTERVAL)

    async def stop(self) -> None:
        """优雅关闭 WebSocket 连接。"""
        self.running = False
        if self.ws:
            await self.ws.close()
            logger.info("WebSocket 连接已关闭")

    def update_addresses(self, new_addresses: Set[str]) -> None:
        """
        更新监控地址列表并触发重连，以便立即生效。

        参数:
            new_addresses: 新的地址集合
        """
        old_addresses = set(self.addresses)
        self.addresses = set(new_addresses)

        added = len(self.addresses - old_addresses)
        removed = len(old_addresses - self.addresses)
        logger.info(
            f"地址列表已更新，共 {len(self.addresses)} 个地址 "
            f"(+{added}, -{removed})"
        )

        # 已运行时主动重连，确保新地址无需等待断线即可订阅。
        if self.running and self.ws:
            self._reconnect_requested = True
            try:
                asyncio.create_task(self.ws.close())
            except Exception as e:
                logger.warning(f"触发 WebSocket 重连失败: {e}")

    async def _connect_and_listen(self) -> None:
        """建立连接、订阅地址、持续监听消息。"""
        logger.info(f"正在连接 {config.MEMPOOL_WS_URL} ...")

        try:
            async with websockets.connect(
                config.MEMPOOL_WS_URL,
                ping_interval=config.WS_PING_INTERVAL,
                ping_timeout=10,
                close_timeout=5,
            ) as ws:
                self.ws = ws
                logger.info("WebSocket 连接成功")

                # 分批订阅地址
                await self._subscribe_addresses(ws)

                # 持续监听消息
                async for message in ws:
                    if not self.running:
                        break
                    await self._handle_message(message)
        finally:
            self.ws = None
            if self._reconnect_requested:
                logger.info("已应用地址更新，WebSocket 正在重连并重新订阅")
                self._reconnect_requested = False

    async def _subscribe_addresses(self, ws) -> None:
        """
        分批向 mempool.space 订阅地址追踪。

        每次订阅 WS_BATCH_SIZE 个地址，批次间休眠 WS_BATCH_DELAY 秒，
        避免触发服务端限流。

        参数:
            ws: WebSocket 连接对象
        """
        self.subscribed_count = 0
        addresses_list = list(self.addresses)
        total = len(addresses_list)

        if total == 0:
            logger.warning("当前地址列表为空，跳过 WebSocket 订阅")
            return

        for i in range(0, total, config.WS_BATCH_SIZE):
            batch = addresses_list[i:i + config.WS_BATCH_SIZE]
            for addr in batch:
                subscribe_msg = json.dumps({"track-address": addr})
                await ws.send(subscribe_msg)
                self.subscribed_count += 1

            progress = min(self.subscribed_count, total)
            logger.info(
                f"地址订阅进度: {progress}/{total} "
                f"({progress * 100 // total}%)"
            )

            # 批次间延迟
            if i + config.WS_BATCH_SIZE < total:
                await asyncio.sleep(config.WS_BATCH_DELAY)

        logger.info(f"地址订阅完成，共订阅 {self.subscribed_count} 个地址")

    async def _handle_message(self, raw_message: str) -> None:
        """
        处理 WebSocket 推送消息。

        mempool.space 可能推送多种消息类型，
        我们只关注 address-transactions 字段。

        参数:
            raw_message: 原始 JSON 字符串
        """
        try:
            data = json.loads(raw_message)
        except json.JSONDecodeError:
            logger.warning(f"收到非 JSON 消息，已忽略: {raw_message[:100]}")
            return

        # 检查 address-transactions 字段
        addr_txs = data.get("address-transactions")
        if addr_txs is None:
            # 可能是其他类型消息（如 block、mempool-blocks 等），静默忽略
            return

        # 提取交易列表
        # 格式: {"address": "...", "mempool-transactions": [...], "confirmed-transactions": [...]}
        mempool_txs = addr_txs.get("mempool-transactions", [])
        confirmed_txs = addr_txs.get("confirmed-transactions", [])

        all_txs = mempool_txs + confirmed_txs

        for tx in all_txs:
            try:
                await self.on_transaction(tx)
            except Exception as e:
                logger.error(f"处理交易回调时出错: {e}")
