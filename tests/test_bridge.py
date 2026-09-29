from __future__ import annotations

import json
import socket
import threading

import pytest

from material_maker_mcp.bridge import (
    BridgeConfig,
    MaterialMakerBridge,
    MaterialMakerBridgeError,
)


def _serve_once(response_factory):
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    port = listener.getsockname()[1]

    def serve():
        connection, _ = listener.accept()
        with connection:
            request = json.loads(connection.makefile("r", encoding="utf-8").readline())
            response = response_factory(request)
            connection.sendall((json.dumps(response) + "\n").encode())
        listener.close()

    threading.Thread(target=serve, daemon=True).start()
    return port


def test_bridge_round_trip_and_request_shape():
    captured = {}

    def response(request):
        captured.update(request)
        return {"id": request["id"], "ok": True, "result": {"pong": True}}

    port = _serve_once(response)
    bridge = MaterialMakerBridge(BridgeConfig(port=port, timeout=2))
    assert bridge.call("ping", {"value": 3}) == {"pong": True}
    assert captured["action"] == "ping"
    assert captured["args"] == {"value": 3}


def test_bridge_surfaces_material_maker_error():
    def response(request):
        return {"id": request["id"], "ok": False, "error": "bad port"}

    port = _serve_once(response)
    bridge = MaterialMakerBridge(BridgeConfig(port=port, timeout=2))
    with pytest.raises(MaterialMakerBridgeError, match="bad port"):
        bridge.call("connect_nodes")


def test_bridge_preserves_structured_error_context():
    def response(request):
        return {
            "id": request["id"],
            "ok": False,
            "error": "fragment rejected",
            "code": "validation_failed",
            "possible_solutions": ["validate first"],
            "details": {"errors": ["bad port"]},
        }

    port = _serve_once(response)
    bridge = MaterialMakerBridge(BridgeConfig(port=port, timeout=2))
    with pytest.raises(MaterialMakerBridgeError) as raised:
        bridge.call("add_graph_fragment")
    assert raised.value.code == "validation_failed"
    assert raised.value.possible_solutions == ["validate first"]
    assert raised.value.details == {"errors": ["bad port"]}


def test_bridge_rejects_non_loopback_environment(monkeypatch):
    monkeypatch.setenv("MATERIAL_MAKER_BRIDGE_HOST", "192.0.2.1")
    with pytest.raises(MaterialMakerBridgeError, match="loopback"):
        BridgeConfig.from_env()


@pytest.mark.parametrize("port", [0, -1, 65536])
def test_rejects_invalid_ports(port):
    with pytest.raises(ValueError, match="port"):
        BridgeConfig(port=port)


@pytest.mark.parametrize("timeout", [0, -1, float("inf"), float("nan")])
def test_rejects_invalid_timeouts(timeout):
    with pytest.raises(ValueError, match="timeout"):
        BridgeConfig(timeout=timeout)


def test_direct_config_rejects_remote_host():
    with pytest.raises(MaterialMakerBridgeError, match="loopback"):
        BridgeConfig(host="192.0.2.1")


@pytest.mark.parametrize("payload", [[], None, "not an envelope"])
def test_rejects_non_object_responses(payload):
    port = _serve_once(lambda _request: payload)
    with pytest.raises(MaterialMakerBridgeError, match="non-object"):
        MaterialMakerBridge(BridgeConfig(port=port, timeout=2)).call("ping")


def test_rejects_mismatched_request_id():
    port = _serve_once(lambda req: {"id": req["id"] + 1, "ok": True})
    with pytest.raises(MaterialMakerBridgeError, match="mismatched"):
        MaterialMakerBridge(BridgeConfig(port=port, timeout=2)).call("ping")


class _Chunks:
    def __init__(self, *chunks):
        self.chunks = iter(chunks)

    def recv(self, _size):
        return next(self.chunks, b"")


@pytest.mark.parametrize("chunks", [(b"123456\n",), (b"123", b"456\n")])
def test_response_limit_includes_final_chunk(monkeypatch, chunks):
    monkeypatch.setattr("material_maker_mcp.bridge.MAX_RESPONSE_BYTES", 5)
    with pytest.raises(MaterialMakerBridgeError, match="exceeds"):
        MaterialMakerBridge._read_line(_Chunks(*chunks))


def test_response_at_limit_accepts_split_utf8(monkeypatch):
    monkeypatch.setattr("material_maker_mcp.bridge.MAX_RESPONSE_BYTES", 2)
    assert MaterialMakerBridge._read_line(_Chunks(b"\xc3", b"\xa4\n")) == "ä"


def test_invalid_utf8_is_a_bridge_error():
    with pytest.raises(MaterialMakerBridgeError, match="UTF-8"):
        MaterialMakerBridge._read_line(_Chunks(b"\xff\n"))


def test_closed_response_is_a_bridge_error():
    with pytest.raises(MaterialMakerBridgeError, match="without a response"):
        MaterialMakerBridge._read_line(_Chunks(b"partial"))
