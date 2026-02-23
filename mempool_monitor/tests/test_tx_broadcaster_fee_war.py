import sys
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from mempool_monitor.tx_broadcaster import TransactionBroadcaster


def test_filter_competing_txs_only_keeps_conflicts_and_sorts():
    broadcaster = TransactionBroadcaster()
    watched_outpoints = {("aaa", 0), ("bbb", 1)}
    own_txids = {"selftx"}

    txs = [
        {
            "txid": "selftx",
            "vin": [{"txid": "aaa", "vout": 0}],
            "fee": 1000,
            "weight": 400,
        },
        {
            "txid": "enemy_low",
            "vin": [{"txid": "aaa", "vout": 0}],
            "fee": 800,
            "weight": 400,
        },
        {
            "txid": "enemy_high",
            "vin": [{"txid": "bbb", "vout": 1}],
            "fee": 2400,
            "weight": 400,
        },
        {
            "txid": "unrelated",
            "vin": [{"txid": "ccc", "vout": 9}],
            "fee": 10000,
            "weight": 400,
        },
    ]

    competing = broadcaster._filter_competing_txs(
        txs=txs,
        watched_outpoints=watched_outpoints,
        own_txids=own_txids,
    )

    assert [item["txid"] for item in competing] == [
        "enemy_high",
        "enemy_low",
    ]
    assert competing[0]["fee_rate"] > competing[1]["fee_rate"]


def test_compute_initial_fee_rate_respects_floor_and_multiplier():
    broadcaster = TransactionBroadcaster()
    broadcaster.fee_rate = 100
    broadcaster.fee_multiplier = 3

    assert broadcaster._compute_initial_fee_rate(None) == 100
    assert broadcaster._compute_initial_fee_rate(20.0) == 100
    assert broadcaster._compute_initial_fee_rate(40.0) == 120


def test_compute_bump_fee_rate_has_no_cap_and_must_increase():
    broadcaster = TransactionBroadcaster()
    broadcaster.fee_rate = 100
    broadcaster.fee_multiplier = 3

    # 高竞争费率会直接按倍数放大，不做上限裁剪
    assert broadcaster._compute_bump_fee_rate(500.0, current_fee_rate=800) == 1500

    # 即使倍数目标未超过当前费率，也至少 +1
    assert broadcaster._compute_bump_fee_rate(200.0, current_fee_rate=700) == 701


def test_extract_outpoints_supports_object_and_dict():
    broadcaster = TransactionBroadcaster()

    unspents = [
        SimpleNamespace(txid="abcd", txindex=0),
        {"txid": "efgh", "vout": 2},
    ]

    outpoints = broadcaster._extract_outpoints(unspents)

    assert ("abcd", 0) in outpoints
    assert ("efgh", 2) in outpoints
