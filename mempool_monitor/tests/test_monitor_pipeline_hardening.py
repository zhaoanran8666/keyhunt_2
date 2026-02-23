import asyncio
import sys
import types
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

# 测试环境可能未安装 websockets，注入最小桩模块避免导入失败。
if "websockets" not in sys.modules:
    fake_websockets = types.ModuleType("websockets")
    fake_exceptions = types.ModuleType("websockets.exceptions")

    class _FakeConnectionError(Exception):
        pass

    fake_websockets.connect = None
    fake_exceptions.ConnectionClosed = _FakeConnectionError
    fake_exceptions.ConnectionClosedError = _FakeConnectionError
    fake_exceptions.ConnectionClosedOK = _FakeConnectionError

    sys.modules["websockets"] = fake_websockets
    sys.modules["websockets.exceptions"] = fake_exceptions

from mempool_monitor.address_loader import AddressWatcher
from mempool_monitor.kangaroo_solver import KangarooSolver
from mempool_monitor.monitor import MempoolMonitor
from mempool_monitor.rest_client import BlockstreamRestClient
from mempool_monitor.tx_broadcaster import TransactionBroadcaster
from mempool_monitor.websocket_client import MempoolWebSocketClient


def test_address_watcher_reload_error_does_not_raise(tmp_path):
    addr_file = tmp_path / "watch.txt"
    addr_file.write_text("1BoatSLRHtKNngkdXEeobR76b53LETtpyT\n", encoding="utf-8")
    watcher = AddressWatcher(addr_file)
    watcher.last_mtime = 0.0

    def _boom():
        raise RuntimeError("reload failed")

    watcher.reload = _boom  # type: ignore[assignment]

    assert watcher.check_and_reload() is False


def test_monitor_txid_normalize_and_dedupe():
    monitor = MempoolMonitor(enable_rest=False)

    txid = monitor._normalize_txid("  ABCD1234  ")
    assert txid == "abcd1234"

    assert monitor._remember_txid(txid) is True
    assert monitor._remember_txid(txid) is False


def test_rest_update_addresses_tracks_pending_baseline():
    async def _dummy(_tx):
        return None

    client = BlockstreamRestClient(addresses={"a"}, on_transaction=_dummy)
    client.update_addresses({"a", "b", "c"})

    pending = client._consume_pending_baseline_addresses()
    assert pending == {"b", "c"}
    assert client.addresses == {"a", "b", "c"}


def test_kangaroo_solver_normalize_pubkey_supports_uncompressed():
    solver = KangarooSolver()
    x = "11" * 32
    y = "22" * 32  # y 最后一位是 2，偶数 => 前缀 02
    uncompressed = f"04{x}{y}"

    compressed = solver._normalize_pubkey(uncompressed)
    assert compressed == f"02{x}".upper()
    assert len(compressed) == 66


def test_websocket_update_addresses_triggers_reconnect_close():
    async def _run():
        async def _dummy(_tx):
            return None

        class FakeWS:
            def __init__(self):
                self.close_called = False

            async def close(self):
                self.close_called = True

        client = MempoolWebSocketClient(addresses={"a"}, on_transaction=_dummy)
        client.running = True
        client.ws = FakeWS()

        client.update_addresses({"a", "b"})
        await asyncio.sleep(0)

        assert client.ws.close_called is True

    asyncio.run(_run())


def test_check_tx_confirmed_uses_fallback(monkeypatch):
    async def _run():
        broadcaster = TransactionBroadcaster()

        async def _fake_query(session, api_base, txid, source_name):
            if source_name == "mempool.space":
                return None
            return True

        monkeypatch.setattr(
            broadcaster,
            "_query_tx_confirmed_status",
            _fake_query,
        )

        assert await broadcaster._check_tx_confirmed(None, "x" * 64) is True

    asyncio.run(_run())
