from __future__ import annotations

import importlib.util
import subprocess
from pathlib import Path

import pytest

SPEC = importlib.util.spec_from_file_location(
    "install_bridge", Path(__file__).resolve().parents[1] / "scripts/install_bridge.py"
)
installer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(installer)


@pytest.fixture
def checkout(tmp_path, monkeypatch):
    root = tmp_path / "app"
    root.mkdir()
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    addon = root / installer.ADDON
    addon.mkdir(parents=True)
    (addon / "mcp_bridge.gd").write_text("original bridge\n")
    (addon / "README.md").write_text("original docs\n")
    (root / "project.godot").write_text('mcp_bridge="*res://addons/mcp_bridge/mcp_bridge.gd"\n')
    subprocess.run(["git", "-C", str(root), "add", "."], check=True)
    subprocess.run(
        [
            "git",
            "-C",
            str(root),
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.invalid",
            "commit",
            "-qm",
            "fixture",
        ],
        check=True,
    )
    monkeypatch.setattr(
        installer, "UPSTREAM_COMMIT", installer.git(root, "rev-parse", "HEAD").decode().strip()
    )
    return root


def test_install_is_repeatable_and_preserves_unrelated_files(checkout):
    extra = checkout / "unrelated.txt"
    extra.write_text("keep me")
    installer.install(checkout)
    installer.install(checkout)
    assert extra.read_text() == "keep me"
    assert (checkout / installer.ADDON / "mcp_bridge.gd").read_bytes() == (
        installer.ROOT / installer.ADDON / "mcp_bridge.gd"
    ).read_bytes()


def test_modified_destination_aborts_before_any_write(checkout):
    addon = checkout / installer.ADDON
    (addon / "mcp_bridge.gd").write_text("user modifications\n")
    with pytest.raises(ValueError, match="locally modified"):
        installer.install(checkout)
    assert (addon / "README.md").read_text() == "original docs\n"
    assert (addon / "mcp_bridge.gd").read_text() == "user modifications\n"


def test_unreviewed_revision_is_rejected(checkout, monkeypatch):
    monkeypatch.setattr(installer, "UPSTREAM_COMMIT", "0" * 40)
    with pytest.raises(ValueError, match="expected upstream commit"):
        installer.install(checkout)
