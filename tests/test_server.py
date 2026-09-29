from __future__ import annotations

from material_maker_mcp import server


def test_list_node_types_filters_and_limits(monkeypatch):
    items = [
        {"name": "brick", "category": "Pattern"},
        {"name": "noise", "category": "Noise"},
        {"name": "noise_2", "category": "Noise"},
    ]

    monkeypatch.setattr(server, "call_bridge", lambda *_args, **_kwargs: items)
    result = server.list_node_types(query="noise", limit=1)
    assert result == [{"name": "noise", "category": "Noise"}]


def test_save_material_resolves_explicit_path(monkeypatch, tmp_path):
    captured = {}

    def fake_call(action, **arguments):
        captured.update({"action": action, **arguments})
        return {"saved": arguments["path"]}

    monkeypatch.setattr(server, "call_bridge", fake_call)
    target = tmp_path / "example.ptex"
    result = server.save_material(str(target))
    assert captured == {"action": "save_material", "path": str(target.resolve())}
    assert result["saved"] == str(target.resolve())


def test_material_id_is_forwarded_only_when_present(monkeypatch):
    calls = []

    def fake_call(action, **arguments):
        calls.append((action, arguments))
        return arguments

    monkeypatch.setattr(server, "call_bridge", fake_call)
    server.get_material_graph()
    server.get_material_graph("material-7")
    assert calls == [
        ("get_graph", {}),
        ("get_graph", {"material_id": "material-7"}),
    ]


def test_validation_tool_is_read_only():
    tool = server.mcp._tool_manager.get_tool("validate_graph_fragment")
    assert tool is not None
    assert tool.annotations is not None
    assert tool.annotations.readOnlyHint is True
    assert tool.annotations.destructiveHint is False


def test_preview_material_maps_embeds_files_before_temp_cleanup(monkeypatch):
    png = b"\x89PNG\r\n\x1a\nexample"

    def fake_export(prefix, profile, size, material_id):
        path = server.Path(f"{prefix}_albedo.png")
        path.write_bytes(png)
        return {
            "material_id": material_id or "material-1",
            "files": [
                {
                    "path": str(path),
                    "filename": path.name,
                    "channel": "albedo",
                    "extension": "png",
                    "size_bytes": len(png),
                    "sha256": "abc123",
                }
            ],
        }

    monkeypatch.setattr(server, "export_material", fake_export)
    content = server.preview_material_maps(size=64, material_id="material-1")
    assert content[0]["files"][0]["channel"] == "albedo"
    assert content[1] == "PBR map: albedo"
    assert content[2].data == png


def test_preview_material_maps_is_read_only_unstructured():
    tool = server.mcp._tool_manager.get_tool("preview_material_maps")
    assert tool is not None
    assert tool.annotations is not None
    assert tool.annotations.readOnlyHint is True
    assert tool.output_schema is None


def test_preview_material_variations_embeds_images_and_reports_restoration(
    monkeypatch,
):
    png = b"\x89PNG\r\n\x1a\nvariation"

    def fake_render(**arguments):
        path = server.Path(arguments["output_dir"]) / "variation_001.png"
        path.write_bytes(png)
        return {
            "material_id": "material-3",
            "combination_count": 1,
            "state_restored": True,
            "results": [
                {
                    "index": 1,
                    "values": {"Noise.scale": 2.0},
                    "output": {"path": str(path)},
                }
            ],
        }

    monkeypatch.setattr(server, "render_material_variations", fake_render)
    content = server.preview_material_variations(
        {"Noise": {"scale": [2.0]}}, material_id="material-3"
    )
    assert content[0]["state_restored"] is True
    assert content[1].startswith("Variation 1:")
    assert content[2].data == png


def test_variation_tools_have_safe_annotations():
    render_tool = server.mcp._tool_manager.get_tool("render_material_variations")
    preview_tool = server.mcp._tool_manager.get_tool("preview_material_variations")
    assert render_tool is not None and render_tool.annotations is not None
    assert render_tool.annotations.destructiveHint is True
    assert preview_tool is not None and preview_tool.annotations is not None
    assert preview_tool.annotations.readOnlyHint is True
    assert preview_tool.output_schema is None
