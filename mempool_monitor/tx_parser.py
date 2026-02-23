"""
Mempool 监控模块 — 交易解析器

职责：
- 解析 mempool.space 推送的交易 JSON 数据
- 判断交易是否涉及监控中的 Puzzle 地址
- 从交易输入（vin）中提取暴露的公钥
- 从交易输出（vout）中提取目标地址（资金流向）

关键概念：
  当一个 P2PKH 地址被花费时，交易输入的 scriptsig 中会包含：
    <签名> <公钥>
  公钥被暴露意味着私钥已被找到，这是截胡攻击的起点。
"""

import logging
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Set

logger = logging.getLogger(__name__)


@dataclass
class ParsedTransaction:
    """
    解析后的交易数据结构。

    属性:
        txid (str): 交易哈希
        matched_address (str): 匹配到的监控地址
        direction (str): "spending" 表示该地址在花费资金，"receiving" 表示该地址在接收资金
        pubkey (str | None): 从 scriptsig 中提取的公钥（仅花费时有）
        destination_addresses (list[str]): 资金流向地址列表
        fee (int): 交易手续费（satoshis）
        size (int): 交易大小（vbytes）
        raw_data (dict): 原始交易 JSON 数据
    """
    txid: str
    matched_address: str
    direction: str  # "spending" | "receiving"
    pubkey: Optional[str] = None
    destination_addresses: List[str] = field(default_factory=list)
    fee: int = 0
    size: int = 0
    raw_data: Dict = field(default_factory=dict)


def extract_pubkey_from_scriptsig(scriptsig_asm: str) -> Optional[str]:
    """
    从 scriptSig 的 ASM 表示中提取公钥。

    P2PKH 的 scriptSig 格式为: "<签名> <公钥>"
    公钥可能是压缩格式（33字节/66个hex字符，以 02 或 03 开头）
    或非压缩格式（65字节/130个hex字符，以 04 开头）

    参数:
        scriptsig_asm: scriptSig 的人类可读 ASM 字符串
                       格式例如 "OP_PUSHBYTES_72 <sig_hex> OP_PUSHBYTES_33 <pubkey_hex>"

    返回:
        str | None: 提取到的公钥十六进制字符串，未找到则返回 None
    """
    if not scriptsig_asm:
        return None

    # 按空格分割 ASM 字段
    parts = scriptsig_asm.split()

    for part in parts:
        # 检查是否是有效的十六进制字符串
        if not all(c in "0123456789abcdef" for c in part.lower()):
            continue

        # 压缩公钥: 33 字节 = 66 hex 字符, 以 02 或 03 开头
        if len(part) == 66 and part[:2] in ("02", "03"):
            return part

        # 非压缩公钥: 65 字节 = 130 hex 字符, 以 04 开头
        if len(part) == 130 and part[:2] == "04":
            return part

    return None


def extract_pubkey_from_witness(witness: List[str]) -> Optional[str]:
    """
    从 witness 数据中提取公钥（用于 SegWit P2WPKH 交易）。

    P2WPKH 的 witness 格式为: [<签名>, <公钥>]

    参数:
        witness: witness 字段列表，每个元素为十六进制字符串

    返回:
        str | None: 提取到的公钥十六进制字符串，未找到则返回 None
    """
    if not witness or len(witness) < 2:
        return None

    # witness 的第二个元素通常是公钥
    potential_pubkey = witness[1]

    # 压缩公钥检查
    if len(potential_pubkey) == 66 and potential_pubkey[:2] in ("02", "03"):
        return potential_pubkey

    # 非压缩公钥检查
    if len(potential_pubkey) == 130 and potential_pubkey[:2] == "04":
        return potential_pubkey

    return None


def parse_transaction(tx_data: Dict, watched_addresses: Set[str]) -> List[ParsedTransaction]:
    """
    解析单笔交易，检查是否涉及监控地址。

    参数:
        tx_data: mempool.space 格式的交易 JSON 数据
        watched_addresses: 监控中的地址集合

    返回:
        list[ParsedTransaction]: 匹配到的解析结果列表
                                 （一笔交易可能同时涉及多个监控地址）
    """
    results = []
    txid = tx_data.get("txid", "unknown")

    # === 检查交易输入（vin）：是否有监控地址在花费资金 ===
    for vin in tx_data.get("vin", []):
        prevout = vin.get("prevout", {})
        addr = prevout.get("scriptpubkey_address", "")

        if addr in watched_addresses:
            # 尝试从 scriptsig 提取公钥
            pubkey = extract_pubkey_from_scriptsig(
                vin.get("scriptsig_asm", "")
            )
            # 若 scriptsig 无公钥，尝试从 witness 提取
            if pubkey is None:
                pubkey = extract_pubkey_from_witness(
                    vin.get("witness", [])
                )

            # 收集所有输出地址（资金流向）
            dest_addrs = []
            for vout in tx_data.get("vout", []):
                dest = vout.get("scriptpubkey_address", "")
                if dest:
                    dest_addrs.append(dest)

            parsed = ParsedTransaction(
                txid=txid,
                matched_address=addr,
                direction="spending",
                pubkey=pubkey,
                destination_addresses=dest_addrs,
                fee=tx_data.get("fee", 0),
                size=tx_data.get("weight", 0) // 4 if tx_data.get("weight") else 0,
                raw_data=tx_data,
            )
            results.append(parsed)

            if pubkey:
                logger.critical(
                    f"🔑 公钥已暴露！地址 {addr} 正在花费资金！"
                    f"公钥: {pubkey[:16]}..."
                )
            else:
                logger.warning(
                    f"⚠️ 地址 {addr} 正在花费资金，但未能提取公钥"
                )

    # === 检查交易输出（vout）：是否有监控地址在接收资金 ===
    for vout in tx_data.get("vout", []):
        addr = vout.get("scriptpubkey_address", "")

        if addr in watched_addresses:
            parsed = ParsedTransaction(
                txid=txid,
                matched_address=addr,
                direction="receiving",
                fee=tx_data.get("fee", 0),
                size=tx_data.get("weight", 0) // 4 if tx_data.get("weight") else 0,
                raw_data=tx_data,
            )
            results.append(parsed)
            logger.info(f"📥 地址 {addr} 收到新交易 {txid[:16]}...")

    return results
