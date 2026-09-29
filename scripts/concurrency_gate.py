"""Prove that independent host processes safely share the bridge-wide queue."""

from __future__ import annotations

import time
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
from tempfile import TemporaryDirectory

from material_maker_mcp.bridge import call_bridge


def _capture(path: str, material_id: str, rotation_y: float) -> tuple[float, dict]:
    started = time.perf_counter()
    result = call_bridge(
        "render_material_preview",
        path=path,
        size=[128, 128],
        model="sphere",
        rotation=[-15.0, rotation_y, 0.0],
        material_id=material_id,
    )
    return time.perf_counter() - started, result


def _png_size(path: Path) -> tuple[int, int]:
    data = path.read_bytes()
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise RuntimeError(f"not a PNG: {path}")
    return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")


def main() -> None:
    before = call_bridge("list_materials")
    material_id = str(before["active_material_id"])
    if not material_id:
        raise RuntimeError("open a material before running the concurrency gate")
    with TemporaryDirectory(prefix="material-maker-concurrency-") as temp_dir:
        paths = [Path(temp_dir) / "client-a.png", Path(temp_dir) / "client-b.png"]
        wall_started = time.perf_counter()
        with ProcessPoolExecutor(max_workers=2) as pool:
            futures = [
                pool.submit(_capture, str(paths[0]), material_id, 20.0),
                pool.submit(_capture, str(paths[1]), material_id, 55.0),
            ]
            results = [future.result(timeout=60) for future in futures]
        wall_elapsed = time.perf_counter() - wall_started
        if any(_png_size(path) != (128, 128) for path in paths):
            raise RuntimeError("one concurrent client received an invalid preview")
        if any(result[1].get("material_id") != material_id for result in results):
            raise RuntimeError(f"material identity changed during concurrency gate: {results}")
    after = call_bridge("list_materials")
    diagnostics = call_bridge("get_diagnostics")
    if after["active_material_id"] != before["active_material_id"]:
        raise RuntimeError("concurrent previews did not restore the active tab")
    if diagnostics["queue_depth"] != 0:
        raise RuntimeError(f"bridge queue did not drain: {diagnostics}")
    durations = ", ".join(f"{duration:.2f}s" for duration, _ in results)
    print(
        "Two-process bridge queue gate OK: "
        f"client durations [{durations}], wall {wall_elapsed:.2f}s, active tab restored"
    )


if __name__ == "__main__":
    main()
