"""Install this addon into a separate checkout of the reviewed upstream revision."""

from __future__ import annotations

import argparse
import subprocess
from pathlib import Path

UPSTREAM_COMMIT = "3a0a4bbd2662fd647f08767fe36d03024fd0d0c0"
ROOT = Path(__file__).resolve().parents[1]
ADDON = Path("addons/mcp_bridge")


def git(checkout: Path, *args: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(checkout), *args])


def install(checkout: Path) -> None:
    checkout = checkout.resolve(strict=True)
    if git(checkout, "rev-parse", "HEAD").decode().strip() != UPSTREAM_COMMIT:
        raise ValueError(f"expected upstream commit {UPSTREAM_COMMIT}; use a separate checkout")
    project = (checkout / "project.godot").read_text(encoding="utf-8")
    if 'mcp_bridge="*res://addons/mcp_bridge/mcp_bridge.gd"' not in project:
        raise ValueError("upstream project is missing the expected MCP autoload")
    replacements = []
    for source in sorted((ROOT / ADDON).iterdir()):
        if not source.is_file():
            continue
        relative = ADDON / source.name
        target = checkout / relative
        if target.is_symlink():
            raise ValueError(f"refusing symbolic-link destination: {target}")
        target.resolve().relative_to(checkout)
        new = source.read_bytes()
        if target.exists():
            current = target.read_bytes().replace(b"\r\n", b"\n")
            if current != new.replace(b"\r\n", b"\n"):
                upstream = subprocess.run(
                    ["git", "-C", str(checkout), "show", f"HEAD:{relative.as_posix()}"],
                    capture_output=True,
                    check=False,
                )
                if upstream.returncode or current != upstream.stdout.replace(b"\r\n", b"\n"):
                    raise ValueError(f"refusing to overwrite locally modified file: {target}")
        replacements.append((target, new))
    for target, data in replacements:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    print(f"Installed {len(replacements)} addon files into {checkout}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkout", type=Path)
    install(parser.parse_args().checkout)


if __name__ == "__main__":
    main()
