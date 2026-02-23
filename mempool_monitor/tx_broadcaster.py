"""
Mempool 监控模块 — 交易构造与广播

职责：
- 用求解出的私钥构造 P2PKH 交易
- 将目标地址的全部余额转至安全接收地址
- 设置极高手续费确保优先打包
- 通过多节点并发广播已签名交易

广播渠道：
  1. mempool.space POST /api/tx
  2. blockstream.info POST /api/tx
  3. MARA Slipstream（可选）

安全注意事项：
  - 安全接收地址必须在 config.py 中预先配置
  - 交易构造在内存中完成，私钥不持久化
  - 广播前进行交易合法性自检
"""

import asyncio
import inspect
import json
import logging
import math
import time
from typing import Any, Dict, List, Optional, Sequence, Set, Tuple

import aiohttp

from . import config
from .kangaroo_solver import SolveResult

logger = logging.getLogger(__name__)

# mempool.space REST API（用于竞价战状态查询）
MEMPOOL_API_BASE = "https://mempool.space/api"

# 广播端点列表
BROADCAST_ENDPOINTS = [
    {
        "name": "mempool.space",
        "url": "https://mempool.space/api/tx",
        "method": "POST",
        "content_type": "text/plain",   # mempool.space 接受纯文本 hex
    },
    {
        "name": "Blockstream",
        "url": "https://blockstream.info/api/tx",
        "method": "POST",
        "content_type": "text/plain",
    },
]

# MARA Slipstream（可选，需要手动启用）
SLIPSTREAM_ENDPOINT = {
    "name": "MARA Slipstream",
    "url": "https://slipstream.mara.com/api/v1/tx",
    "method": "POST",
    "content_type": "application/json",
}


class TransactionBroadcaster:
    """
    交易构造与广播器。

    接收求解出的私钥，自动查询 UTXO、构造交易、签名并广播。

    属性:
        safe_address (str): 安全接收地址
        fee_rate (int): 手续费率 (sat/vByte)
        enable_slipstream (bool): 是否启用 MARA Slipstream
    """

    def __init__(self):
        self.safe_address = config.SAFE_RECEIVE_ADDRESS
        self.fee_rate = int(config.TX_FEE_SAT_PER_VBYTE)
        self.enable_slipstream = config.ENABLE_SLIPSTREAM
        self.fee_multiplier = max(1.0, float(config.FEE_MULTIPLIER))
        self.fee_war_poll_interval = max(1, int(config.FEE_WAR_POLL_INTERVAL))
        self.fee_war_timeout = max(1, int(config.FEE_WAR_TIMEOUT))

    async def execute(self, solve_result: SolveResult) -> bool:
        """
        完整执行：构造交易 → 初始广播 → 竞价战监控 + RBF 加价。

        参数:
            solve_result: Kangaroo 求解结果（含私钥）

        返回:
            bool: True 表示交易已确认
        """
        if not self.safe_address:
            logger.error(
                "❌ 安全接收地址未配置！请在 config.py 中设置 SAFE_RECEIVE_ADDRESS"
            )
            return False

        logger.info(
            f"开始交易构造 — Puzzle {solve_result.puzzle_info.puzzle_number}\n"
            f"  私钥: 0x{solve_result.private_key[:8]}...\n"
            f"  目标: {self.safe_address}"
        )

        try:
            key = self._build_key(solve_result)
            if not key:
                return False

            unspents = self._load_unspents(key)
            if not unspents:
                logger.error("❌ 未查询到可用 UTXO，无法构造交易")
                return False

            watched_outpoints = self._extract_outpoints(unspents)
            if not watched_outpoints:
                logger.warning("⚠️ 未能从 UTXO 中提取 outpoint，竞价监控精度会下降")

            source_address = solve_result.puzzle_info.address

            async with aiohttp.ClientSession(
                timeout=aiohttp.ClientTimeout(total=30)
            ) as session:
                competing = await self._get_competing_txs(
                    session=session,
                    source_address=source_address,
                    watched_outpoints=watched_outpoints,
                    own_txids=set(),
                )

                highest_rate = self._highest_fee_rate(competing)
                initial_fee_rate = self._compute_initial_fee_rate(highest_rate)

                if highest_rate is None:
                    logger.info(
                        f"初始费率决策: {initial_fee_rate} sat/vB (未检测到竞争者)"
                    )
                else:
                    logger.info(
                        f"初始费率决策: {initial_fee_rate} sat/vB "
                        f"(竞争者最高: {highest_rate:.2f} sat/vB)"
                    )

                signed_tx_hex = self._build_and_sign(
                    key=key,
                    fee_rate=initial_fee_rate,
                    unspents=unspents,
                )
                if not signed_tx_hex:
                    return False

                logger.info(
                    f"交易已签名，大小: {len(signed_tx_hex) // 2} bytes\n"
                    f"  交易 Hex: {signed_tx_hex[:40]}..."
                )

                current_txid = await self._broadcast(signed_tx_hex)
                if not current_txid:
                    logger.error("❌ 初始广播失败，竞价战无法启动")
                    return False

                logger.info(
                    f"✅ 初始广播成功: TXID {current_txid[:16]}... "
                    f"(费率 {initial_fee_rate} sat/vB)"
                )

                return await self._fee_war_loop(
                    session=session,
                    key=key,
                    source_address=source_address,
                    watched_outpoints=watched_outpoints,
                    unspents=unspents,
                    current_txid=current_txid,
                    current_fee_rate=initial_fee_rate,
                )

        except Exception as e:
            logger.error(f"交易执行失败: {e}")
            return False

    def _build_key(self, solve_result: SolveResult) -> Optional[Any]:
        """
        从求解结果加载 bit Key 对象并校验余额。

        参数:
            solve_result: 求解结果

        返回:
            Key | None
        """
        try:
            from bit import Key
        except ImportError:
            logger.error("❌ bit 库未安装。请运行: pip install bit")
            return None

        privkey_hex = solve_result.private_key.zfill(64)

        try:
            key = Key.from_hex(privkey_hex)
        except Exception as e:
            logger.error(f"私钥导入失败: {e}")
            return None

        logger.info(f"密钥地址: {key.address}")

        try:
            balance = int(key.get_balance("satoshi"))
            logger.info(f"地址余额: {balance} satoshis ({balance / 1e8:.8f} BTC)")
            if balance <= 0:
                logger.error("❌ 地址余额为 0，无法构造交易")
                return None
        except Exception as e:
            logger.error(f"查询余额失败: {e}")
            return None

        return key

    def _load_unspents(self, key: Any) -> List[Any]:
        """
        拉取地址 UTXO 列表。

        参数:
            key: bit Key 对象

        返回:
            list: UTXO 列表
        """
        try:
            fetched = key.get_unspents()
            if fetched is not None:
                return list(fetched)
            return list(getattr(key, "unspents", []) or [])
        except Exception as e:
            logger.error(f"查询 UTXO 失败: {e}")
            return []

    def _build_and_sign(
        self, key: Any, fee_rate: int, unspents: Sequence[Any]
    ) -> Optional[str]:
        """
        构造并签名交易。

        参数:
            key: bit Key 对象
            fee_rate: 目标费率（sat/vB）
            unspents: 固定 UTXO 列表（用于持续 RBF 重发）

        返回:
            str | None: 签名后的交易十六进制字符串
        """
        create_tx = getattr(key, "create_transaction", None)
        if not callable(create_tx):
            logger.error("bit Key 对象不支持 create_transaction")
            return None

        kwargs: Dict[str, Any] = {
            "leftover": self.safe_address,
            "fee": int(fee_rate),
        }

        # bit 的参数在不同版本略有差异，动态探测以兼容。
        try:
            params = inspect.signature(create_tx).parameters
        except (TypeError, ValueError):
            params = {}

        if "unspents" in params:
            kwargs["unspents"] = list(unspents)
        if "replace_by_fee" in params:
            kwargs["replace_by_fee"] = True

        try:
            return create_tx([], **kwargs)
        except Exception as e:
            logger.error(f"交易构造失败 (fee={fee_rate} sat/vB): {e}")
            return None

    async def _fee_war_loop(
        self,
        session: aiohttp.ClientSession,
        key: Any,
        source_address: str,
        watched_outpoints: Set[Tuple[str, int]],
        unspents: Sequence[Any],
        current_txid: str,
        current_fee_rate: int,
    ) -> bool:
        """
        手续费竞价战主循环。

        策略：
        - 持续监控同一地址下花费同一 UTXO 的竞争交易
        - 发现竞争者费率 >= 我们当前费率时，立刻 RBF 加价重发
        - 不设置手续费上限，直到确认或超时
        """
        start_at = time.monotonic()
        own_txids = {current_txid}

        while True:
            if await self._check_tx_confirmed(session, current_txid):
                logger.info(
                    f"✅ 交易已确认: {current_txid[:16]}... "
                    f"(最终费率 {current_fee_rate} sat/vB)"
                )
                return True

            elapsed = time.monotonic() - start_at
            if elapsed >= self.fee_war_timeout:
                logger.error(
                    f"❌ 手续费竞价战超时 ({self.fee_war_timeout}s)，"
                    f"最后 TXID: {current_txid}"
                )
                return False

            competing = await self._get_competing_txs(
                session=session,
                source_address=source_address,
                watched_outpoints=watched_outpoints,
                own_txids=own_txids,
            )
            highest_rate = self._highest_fee_rate(competing)

            if highest_rate is not None and highest_rate >= current_fee_rate:
                next_fee_rate = self._compute_bump_fee_rate(
                    highest_competing_fee_rate=highest_rate,
                    current_fee_rate=current_fee_rate,
                )
                bump_txid = await self._rbf_bump(
                    key=key,
                    unspents=unspents,
                    new_fee_rate=next_fee_rate,
                )
                if not bump_txid:
                    return False

                current_fee_rate = next_fee_rate
                current_txid = bump_txid
                own_txids.add(bump_txid)
                continue

            await asyncio.sleep(self.fee_war_poll_interval)

    async def _get_competing_txs(
        self,
        session: aiohttp.ClientSession,
        source_address: str,
        watched_outpoints: Set[Tuple[str, int]],
        own_txids: Set[str],
    ) -> List[Dict[str, Any]]:
        """
        查询 mempool 中与目标 UTXO 冲突的竞争交易。

        返回:
            list[dict]: 按费率降序排列，每项包含 txid / fee_rate
        """
        if not watched_outpoints:
            return []

        url = f"{MEMPOOL_API_BASE}/address/{source_address}/txs/mempool"

        try:
            async with session.get(url) as resp:
                if resp.status != 200:
                    body = await resp.text()
                    logger.warning(
                        f"查询竞争交易失败 (HTTP {resp.status}): {body[:200]}"
                    )
                    return []

                txs = await resp.json()
        except Exception as e:
            logger.warning(f"查询竞争交易异常: {e}")
            return []

        return self._filter_competing_txs(
            txs=txs,
            watched_outpoints=watched_outpoints,
            own_txids=own_txids,
        )

    def _filter_competing_txs(
        self,
        txs: List[Dict[str, Any]],
        watched_outpoints: Set[Tuple[str, int]],
        own_txids: Set[str],
    ) -> List[Dict[str, Any]]:
        """
        过滤出真正竞争同一 UTXO 的交易并计算费率。
        """
        competing: List[Dict[str, Any]] = []

        for tx in txs:
            txid = str(tx.get("txid", "")).lower()
            if not txid or txid in own_txids:
                continue

            if not self._tx_spends_watched_outpoint(tx, watched_outpoints):
                continue

            fee_rate = self._compute_tx_fee_rate(tx)
            if fee_rate <= 0:
                continue

            competing.append(
                {
                    "txid": txid,
                    "fee_rate": fee_rate,
                }
            )

        competing.sort(key=lambda item: item["fee_rate"], reverse=True)
        return competing

    def _tx_spends_watched_outpoint(
        self,
        tx: Dict[str, Any],
        watched_outpoints: Set[Tuple[str, int]],
    ) -> bool:
        """
        判断交易是否花费了我们关注的 outpoint。
        """
        for vin in tx.get("vin", []):
            outpoint = self._extract_vin_outpoint(vin)
            if outpoint and outpoint in watched_outpoints:
                return True
        return False

    def _extract_vin_outpoint(
        self, vin: Dict[str, Any]
    ) -> Optional[Tuple[str, int]]:
        """
        从 vin 中提取被花费的 outpoint。
        """
        prev_txid = vin.get("txid")
        prev_vout = vin.get("vout")

        if prev_txid is None or prev_vout is None:
            prevout = vin.get("prevout", {})
            prev_txid = prevout.get("txid", prev_txid)
            prev_vout = prevout.get("vout", prev_vout)

        if prev_txid is None or prev_vout is None:
            return None

        try:
            return str(prev_txid).lower(), int(prev_vout)
        except (TypeError, ValueError):
            return None

    async def _check_tx_confirmed(
        self, session: aiohttp.ClientSession, txid: str
    ) -> bool:
        """
        检查指定交易是否已经确认。

        优先查询 mempool.space，失败/未确认时回退到 Blockstream，
        降低单一数据源异常造成的误判。
        """
        mempool_status = await self._query_tx_confirmed_status(
            session=session,
            api_base=MEMPOOL_API_BASE,
            txid=txid,
            source_name="mempool.space",
        )
        if mempool_status is True:
            return True

        blockstream_status = await self._query_tx_confirmed_status(
            session=session,
            api_base=config.BLOCKSTREAM_API_BASE,
            txid=txid,
            source_name="Blockstream",
        )
        return blockstream_status is True

    async def _query_tx_confirmed_status(
        self,
        session: aiohttp.ClientSession,
        api_base: str,
        txid: str,
        source_name: str,
    ) -> Optional[bool]:
        """
        查询单个数据源对交易确认状态的判断。

        返回:
            True: 已确认
            False: 明确未确认/未找到
            None: 请求失败或响应异常，状态未知
        """
        url = f"{api_base.rstrip('/')}/tx/{txid}/status"

        try:
            async with session.get(url) as resp:
                if resp.status == 200:
                    data = await resp.json()
                    return bool(data.get("confirmed", False))
                if resp.status == 404:
                    return False

                body = await resp.text()
                logger.warning(
                    f"{source_name} 确认状态查询失败 "
                    f"(HTTP {resp.status}): {body[:200]}"
                )
                return None
        except Exception as e:
            logger.warning(f"{source_name} 确认状态查询异常: {e}")
            return None

    async def _rbf_bump(
        self, key: Any, unspents: Sequence[Any], new_fee_rate: int
    ) -> Optional[str]:
        """
        执行一次 RBF 加价重发。

        参数:
            key: bit Key 对象
            unspents: 固定 UTXO 列表
            new_fee_rate: 新费率（sat/vB）

        返回:
            str | None: 新交易 TXID
        """
        signed_tx_hex = self._build_and_sign(
            key=key,
            fee_rate=new_fee_rate,
            unspents=unspents,
        )
        if not signed_tx_hex:
            logger.error("❌ RBF 重构交易失败")
            return None

        txid = await self._broadcast(signed_tx_hex)
        if not txid:
            logger.error("❌ RBF 广播失败")
            return None

        logger.warning(
            f"⚔️ 触发 RBF 加价: {new_fee_rate} sat/vB "
            f"→ 新 TXID {txid[:16]}..."
        )
        return txid

    def _compute_initial_fee_rate(
        self, highest_competing_fee_rate: Optional[float]
    ) -> int:
        """
        初始费率策略：
        - 无竞争者：使用保底费率
        - 有竞争者：max(竞争者最高费率 × 倍数, 保底费率)
        """
        if highest_competing_fee_rate is None:
            return self.fee_rate

        target = int(
            math.ceil(highest_competing_fee_rate * self.fee_multiplier)
        )
        return max(self.fee_rate, target)

    def _compute_bump_fee_rate(
        self, highest_competing_fee_rate: float, current_fee_rate: int
    ) -> int:
        """
        RBF 加价策略（不设上限）：
        - 目标费率 = 竞争者最高费率 × 倍数
        - 若目标未超过当前费率，至少 +1 sat/vB
        """
        target = self._compute_initial_fee_rate(highest_competing_fee_rate)
        if target <= current_fee_rate:
            target = current_fee_rate + 1
        return target

    def _compute_tx_fee_rate(self, tx: Dict[str, Any]) -> float:
        """
        从 mempool 交易对象计算费率（sat/vB）。
        """
        fee = tx.get("fee")
        if fee is None:
            return 0.0

        vsize = tx.get("vsize")
        if not vsize:
            weight = tx.get("weight")
            if weight:
                vsize = float(weight) / 4.0
        if not vsize:
            size = tx.get("size")
            if size:
                vsize = float(size)

        try:
            fee_value = float(fee)
            vsize_value = float(vsize)
        except (TypeError, ValueError):
            return 0.0

        if vsize_value <= 0:
            return 0.0

        return fee_value / vsize_value

    def _highest_fee_rate(
        self, txs: List[Dict[str, Any]]
    ) -> Optional[float]:
        """
        返回竞争交易中的最高费率。
        """
        if not txs:
            return None
        return max(float(tx["fee_rate"]) for tx in txs)

    def _extract_outpoints(
        self, unspents: Sequence[Any]
    ) -> Set[Tuple[str, int]]:
        """
        从 bit Unspent 列表提取 outpoint 集合 (txid, vout)。
        """
        outpoints: Set[Tuple[str, int]] = set()
        for utxo in unspents:
            txid = self._read_field(utxo, "txid")
            vout = self._read_field(utxo, "txindex", "vout")
            if txid is None or vout is None:
                continue
            try:
                outpoints.add((str(txid).lower(), int(vout)))
            except (TypeError, ValueError):
                continue
        return outpoints

    def _read_field(self, obj: Any, *names: str) -> Any:
        """
        兼容 dict / object 两种字段访问方式。
        """
        if isinstance(obj, dict):
            for name in names:
                if name in obj and obj[name] is not None:
                    return obj[name]

        for name in names:
            value = getattr(obj, name, None)
            if value is not None:
                return value

        return None

    async def _broadcast(self, signed_tx_hex: str) -> Optional[str]:
        """
        通过多个节点并发广播已签名交易。

        参数:
            signed_tx_hex: 签名后的交易十六进制字符串

        返回:
            str | None: 至少一个节点成功时返回 TXID
        """
        endpoints = list(BROADCAST_ENDPOINTS)
        if self.enable_slipstream:
            endpoints.append(SLIPSTREAM_ENDPOINT)

        tasks = [
            self._broadcast_to_endpoint(endpoint, signed_tx_hex)
            for endpoint in endpoints
        ]
        results = await asyncio.gather(*tasks, return_exceptions=True)

        success_count = 0
        txid: Optional[str] = None
        for endpoint, result in zip(endpoints, results):
            if isinstance(result, Exception):
                logger.error(f"广播到 {endpoint['name']} 异常: {result}")
                continue
            if result:
                success_count += 1
                if txid is None:
                    txid = result

        logger.info(f"广播结果: {success_count}/{len(endpoints)} 个节点成功")
        return txid

    async def _broadcast_to_endpoint(
        self, endpoint: Dict, signed_tx_hex: str
    ) -> Optional[str]:
        """
        向单个端点广播交易。

        参数:
            endpoint: 端点配置字典
            signed_tx_hex: 交易 hex

        返回:
            str | None: 广播成功返回 TXID
        """
        name = endpoint["name"]
        url = endpoint["url"]

        try:
            async with aiohttp.ClientSession(
                timeout=aiohttp.ClientTimeout(total=30)
            ) as session:

                if endpoint["content_type"] == "application/json":
                    async with session.post(
                        url,
                        json={"rawTx": signed_tx_hex},
                    ) as resp:
                        return await self._handle_response(name, resp)

                async with session.post(
                    url,
                    data=signed_tx_hex,
                    headers={"Content-Type": "text/plain"},
                ) as resp:
                    return await self._handle_response(name, resp)

        except Exception as e:
            logger.error(f"广播到 {name} 失败: {e}")
            return None

    async def _handle_response(
        self, name: str, resp: aiohttp.ClientResponse
    ) -> Optional[str]:
        """
        处理广播响应。

        参数:
            name: 端点名称
            resp: HTTP 响应

        返回:
            str | None: 成功返回 TXID
        """
        body = await resp.text()

        if not (200 <= resp.status < 300):
            logger.warning(
                f"❌ {name} 广播失败 (HTTP {resp.status}): {body[:200]}"
            )
            return None

        txid = self._extract_txid_from_response(body)
        if not txid:
            logger.warning(
                f"⚠️ {name} 广播返回成功但未提取到 TXID: {body[:200]}"
            )
            return None

        logger.info(f"✅ {name} 广播成功！TXID: {txid[:64]}")
        return txid

    def _extract_txid_from_response(self, body: str) -> Optional[str]:
        """
        从广播响应体中提取 TXID。
        """
        direct = body.strip().strip('"').lower()
        if self._is_txid(direct):
            return direct

        try:
            payload = json.loads(body)
        except Exception:
            return None

        for key in ("txid", "id", "hash"):
            value = payload.get(key) if isinstance(payload, dict) else None
            if isinstance(value, str):
                candidate = value.strip().lower()
                if self._is_txid(candidate):
                    return candidate

        if isinstance(payload, dict):
            data = payload.get("data")
            if isinstance(data, dict):
                for key in ("txid", "id", "hash"):
                    value = data.get(key)
                    if isinstance(value, str):
                        candidate = value.strip().lower()
                        if self._is_txid(candidate):
                            return candidate

        return None

    def _is_txid(self, value: str) -> bool:
        """
        判断字符串是否为 64 位十六进制 TXID。
        """
        return (
            len(value) == 64
            and all(ch in "0123456789abcdef" for ch in value)
        )
