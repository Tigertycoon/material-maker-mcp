"""Exercise failure recovery, UTF-8 framing and recipes on a disposable live app."""

from __future__ import annotations

import argparse
import json
import socket
import time
from pathlib import Path
from tempfile import TemporaryDirectory

from material_maker_mcp import server
from material_maker_mcp.bridge import BridgeConfig, MaterialMakerBridgeError, call_bridge


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def run(output: Path) -> None:
    require(call_bridge("get_status")["app_ready"], "application is not ready")
    target = server.new_material()["material_id"]
    control = server.new_material()["material_id"]

    def active() -> str:
        return server.list_materials()["active_material_id"]

    before = server.get_material_graph(target)
    require(active() == control, "graph inspection changed active tab")
    node = server.describe_node_type("uniform_greyscale")
    require(bool(node), "node discovery failed")
    invalid = server.validate_graph_fragment(
        [{"name": "Gray", "type": "uniform_greyscale"}],
        [{"from": "Gray", "from_port": 99, "to": "Material", "to_port": 0}],
        target,
    )
    require(not invalid["valid"], "invalid port was accepted")
    require(server.get_material_graph(target) == before, "validation changed graph")
    require(active() == control, "validation changed active tab")
    for bad_enum in ["xor", -1, 1.5, 9999]:
        rejected = server.validate_graph_fragment(
            [{"name": "Pattern", "type": "pattern", "parameters": {"mix": bad_enum}}],
            [],
            target,
        )
        require(not rejected["valid"], f"invalid enum value accepted: {bad_enum}")
    require(server.get_material_graph(target) == before, "enum validation changed graph")

    for arguments in [
        {"size": [1, 64]},
        {"model": "not-a-model"},
        {"path": str(output / "wrong-extension.txt")},
    ]:
        request = {"material_id": target, "path": str(output / "failure.png"), **arguments}
        try:
            call_bridge("render_material_preview", **request)
        except MaterialMakerBridgeError:
            pass
        else:
            raise RuntimeError(f"invalid preview was accepted: {arguments}")
        require(active() == control, f"failed preview changed active tab: {arguments}")
    print("Invalid fragment leaves graph unchanged; three preview errors restore active tab")

    config = BridgeConfig.from_env()
    # Send a JSON string whose UTF-8 code point crosses two TCP reads.
    request = (
        json.dumps(
            {"id": 901, "action": "describe", "args": {"topic": "action", "name": "prüfen"}},
            ensure_ascii=False,
        ).encode()
        + b"\n"
    )
    split = request.index("ü".encode()) + 1
    with socket.create_connection((config.host, config.port), timeout=config.timeout) as peer:
        peer.settimeout(config.timeout)
        peer.sendall(request[:split])
        time.sleep(0.25)
        peer.sendall(request[split:])
        response = peer.makefile("rb").readline()
    decoded = json.loads(response)
    require(decoded.get("id") == 901, "fragmented request lost its ID")
    require("prüfen" in decoded.get("error", ""), "fragmented UTF-8 was corrupted")
    print("UTF-8 request split inside a multibyte character preserved correctly")

    recipes = server.list_material_recipes()
    for recipe in recipes:
        created = server.apply_material_recipe(recipe["id"])
        path = output / f"{recipe['id']}.png"
        server.save_material_preview(str(path), 128, 128, material_id=created["material_id"])
        data = path.read_bytes()
        require(data.startswith(b"\x89PNG\r\n\x1a\n"), f"invalid PNG for {recipe['id']}")
        require(
            (int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")) == (128, 128),
            f"invalid preview size for {recipe['id']}",
        )
        print(f"Recipe validated, applied and rendered: {recipe['id']}")
    print(f"Live contracts passed; {len(recipes)} recipe previews")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, help="keep images in a new directory")
    parser.add_argument(
        "--app-log", type=Path, help="also reject script errors in the test app log"
    )
    args = parser.parse_args()
    if args.output_dir:
        args.output_dir.mkdir(parents=True, exist_ok=False)
        run(args.output_dir.resolve())
    else:
        with TemporaryDirectory(prefix="material-maker-contracts-") as temp:
            run(Path(temp))
    if args.app_log:
        require(
            "SCRIPT ERROR:" not in args.app_log.read_text(encoding="utf-8", errors="replace"),
            "application log contains GDScript errors; inspect it before accepting this run",
        )
        print("Application log contains no GDScript errors")


if __name__ == "__main__":
    main()
