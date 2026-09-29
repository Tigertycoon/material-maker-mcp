"""Serialized JSON-lines client for Material Maker's loopback bridge."""

from __future__ import annotations

import json
import math
import os
import socket
import threading
from dataclasses import dataclass
from itertools import count
from typing import Any

MAX_RESPONSE_BYTES = 32 * 1024 * 1024
_CALL_LOCK = threading.Lock()
_REQUEST_IDS = count(1)


class MaterialMakerBridgeError(RuntimeError):
    """Raised when Material Maker is unavailable or rejects a request."""

    def __init__(
        self,
        message: str,
        *,
        code: str = "bridge_error",
        possible_solutions: list[str] | None = None,
        details: dict[str, Any] | None = None,
    ) -> None:
        self.code = code
        self.possible_solutions = possible_solutions or []
        self.details = details or {}
        suffix = ""
        if self.possible_solutions:
            suffix = " Possible solutions: " + "; ".join(self.possible_solutions)
        super().__init__(f"[{self.code}] {message}{suffix}")


@dataclass(frozen=True, slots=True)
class BridgeConfig:
    host: str = "127.0.0.1"
    port: int = 8767
    timeout: float = 120.0

    def __post_init__(self) -> None:
        if self.host not in {"127.0.0.1", "localhost", "::1"}:
            raise MaterialMakerBridgeError("bridge host must be a loopback address")
        if not 1 <= self.port <= 65535:
            raise ValueError("bridge port must be between 1 and 65535")
        if not math.isfinite(self.timeout) or self.timeout <= 0:
            raise ValueError("bridge timeout must be finite and positive")

    @classmethod
    def from_env(cls) -> BridgeConfig:
        host = os.environ.get("MATERIAL_MAKER_BRIDGE_HOST", "127.0.0.1")
        if host not in {"127.0.0.1", "localhost", "::1"}:
            raise MaterialMakerBridgeError("MATERIAL_MAKER_BRIDGE_HOST must be a loopback address")
        return cls(
            host=host,
            port=int(os.environ.get("MATERIAL_MAKER_BRIDGE_PORT", "8767")),
            timeout=float(os.environ.get("MATERIAL_MAKER_BRIDGE_TIMEOUT", "120")),
        )


class MaterialMakerBridge:
    def __init__(self, config: BridgeConfig | None = None) -> None:
        self.config = config or BridgeConfig.from_env()

    def call(self, action: str, arguments: dict[str, Any] | None = None) -> Any:
        if not action or not isinstance(action, str):
            raise ValueError("action must be a non-empty string")
        request_id = next(_REQUEST_IDS)
        request = (
            json.dumps(
                {"id": request_id, "action": action, "args": arguments or {}},
                ensure_ascii=False,
                separators=(",", ":"),
            ).encode("utf-8")
            + b"\n"
        )

        with _CALL_LOCK:
            try:
                with socket.create_connection(
                    (self.config.host, self.config.port), timeout=self.config.timeout
                ) as connection:
                    connection.settimeout(self.config.timeout)
                    connection.sendall(request)
                    response = self._read_line(connection)
            except (OSError, TimeoutError) as exc:
                raise MaterialMakerBridgeError(
                    "Material Maker bridge is unavailable at "
                    f"{self.config.host}:{self.config.port}. Start the MCP-enabled "
                    "Material Maker build and enable its MCP server."
                ) from exc

        try:
            payload = json.loads(response)
        except json.JSONDecodeError as exc:
            raise MaterialMakerBridgeError("Material Maker returned invalid JSON") from exc
        if not isinstance(payload, dict):
            raise MaterialMakerBridgeError("Material Maker returned a non-object response")
        if payload.get("id") not in {None, request_id}:
            raise MaterialMakerBridgeError(
                "Material Maker returned a mismatched request id", code="protocol_error"
            )
        if payload.get("ok") is not True:
            raise MaterialMakerBridgeError(
                str(payload.get("error", "unknown bridge error")),
                code=str(payload.get("code", "bridge_error")),
                possible_solutions=list(payload.get("possible_solutions", [])),
                details=dict(payload.get("details", {})),
            )
        return payload.get("result")

    @staticmethod
    def _read_line(connection: socket.socket) -> str:
        chunks: list[bytes] = []
        size = 0
        while True:
            chunk = connection.recv(65536)
            if not chunk:
                raise MaterialMakerBridgeError(
                    "Material Maker closed the connection without a response"
                )
            newline = chunk.find(b"\n")
            part = chunk[:newline] if newline >= 0 else chunk
            size += len(part)
            if size > MAX_RESPONSE_BYTES:
                raise MaterialMakerBridgeError("Material Maker response exceeds 32 MiB")
            chunks.append(part)
            if newline >= 0:
                break
        try:
            return b"".join(chunks).decode("utf-8")
        except UnicodeDecodeError as exc:
            raise MaterialMakerBridgeError("Material Maker returned invalid UTF-8") from exc


_DEFAULT_BRIDGE: MaterialMakerBridge | None = None


def get_bridge() -> MaterialMakerBridge:
    global _DEFAULT_BRIDGE
    if _DEFAULT_BRIDGE is None:
        _DEFAULT_BRIDGE = MaterialMakerBridge()
    return _DEFAULT_BRIDGE


def call_bridge(action: str, **arguments: Any) -> Any:
    return get_bridge().call(action, arguments)
