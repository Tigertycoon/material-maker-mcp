"""Exercise the stdio MCP handshake and a small live Material Maker workflow."""

from __future__ import annotations

import argparse
import asyncio
import base64
import hashlib
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


def _content(result) -> object:
    values = []
    for item in result.content:
        text = getattr(item, "text", None)
        if text:
            value = json.loads(text)
            if isinstance(value, dict) and set(value) == {"result"}:
                value = value["result"]
            values.append(value)
    if not values:
        return None
    return values[0] if len(values) == 1 else values


async def run(live: bool, configured_command: bool = False) -> None:
    if configured_command:
        uv = shutil.which("uv")
        if not uv:
            raise RuntimeError("uv is not available on PATH")
        project = Path(__file__).resolve().parents[1]
        environment = os.environ.copy()
        environment.update(
            {
                "MATERIAL_MAKER_BRIDGE_HOST": "127.0.0.1",
                "MATERIAL_MAKER_BRIDGE_PORT": os.environ.get("MATERIAL_MAKER_BRIDGE_PORT", "8767"),
                "MATERIAL_MAKER_BRIDGE_TIMEOUT": os.environ.get(
                    "MATERIAL_MAKER_BRIDGE_TIMEOUT", "240"
                ),
            }
        )
        params = StdioServerParameters(
            command=uv,
            args=["--directory", str(project), "run", "material-maker-mcp"],
            env=environment,
        )
    else:
        params = StdioServerParameters(
            command=sys.executable,
            args=["-m", "material_maker_mcp.server"],
            env=os.environ.copy(),
        )
    async with stdio_client(params) as (reader, writer):
        async with ClientSession(reader, writer) as session:
            await session.initialize()
            tools = await session.list_tools()
            names = {tool.name for tool in tools.tools}
            required = {
                "material_maker_status",
                "material_maker_diagnostics",
                "list_materials",
                "list_node_types",
                "get_material_graph",
                "validate_graph_fragment",
                "add_graph_fragment",
                "render_node",
                "save_material_preview",
                "preview_material",
                "preview_material_maps",
                "render_material_variations",
                "preview_material_variations",
                "export_material",
                "list_material_recipes",
                "describe_material_recipe",
                "apply_material_recipe",
                "undo",
                "redo",
            }
            missing = required - names
            if missing:
                raise RuntimeError(f"missing MCP tools: {sorted(missing)}")
            print(f"MCP handshake OK; {len(names)} tools registered")
            if not live:
                return

            status = _content(await session.call_tool("material_maker_status", {}))
            if not status or not status.get("app_ready"):
                raise RuntimeError(f"Material Maker is not ready: {status}")
            print(f"Material Maker ready: {status['version']}")

            recipes = _content(await session.call_tool("list_material_recipes", {}))
            if not isinstance(recipes, list) or len(recipes) != 10:
                raise RuntimeError(f"unexpected recipe catalog: {recipes}")
            recipe = _content(
                await session.call_tool("describe_material_recipe", {"recipe_id": "rough_stone"})
            )
            if not recipe or not recipe.get("nodes") or not recipe.get("connections"):
                raise RuntimeError(f"recipe description is incomplete: {recipe}")
            print("Curated 10-recipe catalog discovery OK")

            result = _content(await session.call_tool("new_material", {}))
            if not result or not result.get("created"):
                raise RuntimeError(f"new_material failed: {result}")
            material_id = result.get("material_id")
            if not material_id:
                raise RuntimeError(f"new_material returned no material_id: {result}")
            materials = _content(await session.call_tool("list_materials", {}))
            if material_id not in {item["material_id"] for item in materials["materials"]}:
                raise RuntimeError(f"new material is missing from list_materials: {materials}")
            print(f"Created and identified a fresh material graph: {material_id}")

            node_types = _content(
                await session.call_tool("list_node_types", {"query": "grayscale", "limit": 5})
            )
            if not node_types:
                raise RuntimeError("node type discovery returned no matches")
            if isinstance(node_types, dict):
                node_types = next(
                    (value for value in node_types.values() if isinstance(value, list)), node_types
                )
            if not isinstance(node_types, list):
                raise RuntimeError(f"unexpected node discovery payload: {node_types!r}")
            print(f"Node discovery OK: {node_types[0]}")

            fragment_spec = {
                "material_id": material_id,
                "nodes": [
                    {
                        "name": "MCP_Red",
                        "type": "uniform",
                        "parameters": {
                            "color": {
                                "type": "Color",
                                "r": 0.8,
                                "g": 0.1,
                                "b": 0.1,
                                "a": 1.0,
                            }
                        },
                        "node_position": {"x": -600, "y": -100},
                    },
                    {
                        "name": "MCP_Blue",
                        "type": "uniform",
                        "parameters": {
                            "color": {
                                "type": "Color",
                                "r": 0.1,
                                "g": 0.1,
                                "b": 0.8,
                                "a": 1.0,
                            }
                        },
                        "node_position": {"x": -600, "y": 100},
                    },
                    {
                        "name": "MCP_Blend",
                        "type": "blend",
                        "parameters": {"amount": 0.5},
                        "node_position": {"x": -300, "y": 0},
                    },
                ],
                "connections": [
                    {"from": "MCP_Red", "from_port": 0, "to": "MCP_Blend", "to_port": 0},
                    {"from": "MCP_Blue", "from_port": 0, "to": "MCP_Blend", "to_port": 1},
                ],
            }
            validation = _content(await session.call_tool("validate_graph_fragment", fragment_spec))
            if not validation or not validation.get("valid"):
                raise RuntimeError(f"valid fragment was rejected: {validation}")
            fragment = _content(await session.call_tool("add_graph_fragment", fragment_spec))
            created_names = {item["name"] for item in fragment["nodes"]}
            if not {"MCP_Red", "MCP_Blue", "MCP_Blend"} <= created_names:
                raise RuntimeError(f"batch graph creation failed: {created_names}")
            undo_state = _content(await session.call_tool("undo", {"material_id": material_id}))
            if not undo_state.get("can_redo"):
                raise RuntimeError(f"undo did not expose redo state: {undo_state}")
            redo_state = _content(await session.call_tool("redo", {"material_id": material_id}))
            if not redo_state.get("can_undo"):
                raise RuntimeError(f"redo did not restore undo state: {redo_state}")
            await session.call_tool(
                "connect_nodes",
                {
                    "from_node": "MCP_Blend",
                    "from_port": 0,
                    "to_node": "Material",
                    "to_port": 0,
                    "material_id": material_id,
                },
            )
            print("Validation, batch graph creation, undo/redo, and connections OK")

            node = _content(
                await session.call_tool(
                    "add_node",
                    {
                        "node_type": "uniform_greyscale",
                        "parameters": {"color": 0.35},
                        "position": [-300, 200],
                        "material_id": material_id,
                    },
                )
            )
            node_name = node["name"]
            print(f"Created and inspected node: {node_name}")

            await session.call_tool(
                "connect_nodes",
                {"from_node": node_name, "from_port": 0, "to_node": "Material", "to_port": 2},
            )
            parameter = _content(
                await session.call_tool("get_node_parameter", {"node": node_name, "name": "color"})
            )
            if parameter["value"] != 0.35:
                raise RuntimeError(f"parameter round trip failed: {parameter}")
            print("Parameter and connection operations OK")

            diagnostics = _content(await session.call_tool("material_maker_diagnostics", {}))
            if diagnostics.get("version", {}).get("protocol_version") != 2:
                raise RuntimeError(f"unexpected bridge diagnostics: {diagnostics}")

            duplicate = _content(
                await session.call_tool(
                    "duplicate_node", {"node": node_name, "position": [-100, 350]}
                )
            )
            await session.call_tool("remove_node", {"node": duplicate["name"]})
            print("Duplicate and remove operations OK")

            with tempfile.TemporaryDirectory(prefix="material-maker-mcp-") as temp_dir:
                temp = Path(temp_dir)
                png = temp / "uniform.png"
                preview_png = temp / "preview.png"
                ptex = temp / "smoke.ptex"
                await session.call_tool(
                    "render_node",
                    {
                        "node": node_name,
                        "path": str(png),
                        "output": 0,
                        "width": 64,
                        "height": 64,
                    },
                )
                if not png.is_file() or png.stat().st_size == 0:
                    raise RuntimeError("render_node did not create a PNG")
                preview_result = await session.call_tool(
                    "save_material_preview",
                    {
                        "path": str(preview_png),
                        "width": 128,
                        "height": 128,
                        "model": "sphere",
                        "material_id": material_id,
                    },
                )
                if preview_result.isError or not preview_png.is_file():
                    raise RuntimeError(f"3D preview file failed: {preview_result.content}")
                inline_preview = await session.call_tool(
                    "preview_material",
                    {
                        "width": 128,
                        "height": 128,
                        "model": "sphere",
                        "material_id": material_id,
                    },
                )
                image_items = [item for item in inline_preview.content if hasattr(item, "data")]
                inline_png_ok = image_items and base64.b64decode(image_items[0].data).startswith(
                    b"\x89PNG"
                )
                if not inline_png_ok:
                    raise RuntimeError("preview_material did not return inline PNG image content")
                preview_bytes = base64.b64decode(image_items[0].data)
                if (
                    int.from_bytes(preview_bytes[16:20], "big"),
                    int.from_bytes(preview_bytes[20:24], "big"),
                ) != (128, 128):
                    raise RuntimeError("preview_material returned the wrong image dimensions")
                variation_preview = await session.call_tool(
                    "preview_material_variations",
                    {
                        "variations": {node_name: {"color": [0.15, 0.85]}},
                        "size": 64,
                        "model": "sphere",
                        "material_id": material_id,
                    },
                )
                variation_images = [
                    item for item in variation_preview.content if hasattr(item, "data")
                ]
                variation_metadata = next(
                    json.loads(item.text)
                    for item in variation_preview.content
                    if getattr(item, "text", "").startswith("{")
                )
                restored_parameter = _content(
                    await session.call_tool(
                        "get_node_parameter",
                        {
                            "node": node_name,
                            "name": "color",
                            "material_id": material_id,
                        },
                    )
                )
                if (
                    variation_preview.isError
                    or len(variation_images) != 2
                    or variation_metadata.get("state_restored") is not True
                    or restored_parameter.get("value") != 0.35
                ):
                    raise RuntimeError(
                        "variation rendering did not restore state: "
                        f"{variation_metadata}, parameter={restored_parameter}"
                    )
                print("File/inline 3D previews and restored parameter variations OK")
                await session.call_tool("save_material", {"path": str(ptex)})
                if not ptex.is_file() or ptex.stat().st_size == 0:
                    raise RuntimeError("save_material did not create a .ptex file")
                export_result = await session.call_tool(
                    "export_material",
                    {
                        "prefix": str(temp / "mcp_export"),
                        "profile": "Godot/Godot 4 Standard",
                        "size": 64,
                    },
                )
                if export_result.isError:
                    raise RuntimeError(f"export_material failed: {export_result.content}")
                export_manifest = _content(export_result)
                exported = export_manifest.get("files", []) if export_manifest else []
                if not exported or export_manifest.get("file_count") != len(exported):
                    raise RuntimeError(f"export manifest is incomplete: {export_manifest}")
                for item in exported:
                    path = Path(item["path"])
                    if (
                        not path.is_file()
                        or path.stat().st_size != item["size_bytes"]
                        or hashlib.sha256(path.read_bytes()).hexdigest() != item.get("sha256")
                    ):
                        raise RuntimeError(f"invalid export manifest entry: {item}")
                map_preview = await session.call_tool(
                    "preview_material_maps",
                    {
                        "profile": "Godot/Godot 4 Standard",
                        "size": 64,
                        "material_id": material_id,
                    },
                )
                map_images = [item for item in map_preview.content if hasattr(item, "data")]
                if map_preview.isError or not map_images:
                    raise RuntimeError(f"PBR map preview failed: {map_preview.content}")
                if not all(
                    base64.b64decode(item.data).startswith(b"\x89PNG")
                    for item in map_images
                    if item.mimeType == "image/png"
                ):
                    raise RuntimeError("PBR map preview returned invalid image content")
                await session.call_tool("load_material", {"path": str(ptex)})
                recipe_result = _content(
                    await session.call_tool("apply_material_recipe", {"recipe_id": "matte_clay"})
                )
                if (
                    not recipe_result
                    or not recipe_result.get("validation", {}).get("valid")
                    or len(recipe_result.get("nodes", [])) != 2
                ):
                    raise RuntimeError(f"recipe application failed: {recipe_result}")
                recipe_preview = temp / "matte_clay_preview.png"
                await session.call_tool(
                    "save_material_preview",
                    {
                        "path": str(recipe_preview),
                        "width": 128,
                        "height": 128,
                        "material_id": recipe_result["material_id"],
                    },
                )
                if not recipe_preview.is_file() or recipe_preview.stat().st_size == 0:
                    raise RuntimeError("applied recipe did not produce a 3D preview")
                print(
                    "Render, save, hashed export manifest "
                    f"({len(exported)} files), {len(map_images)} PBR images, reload, and recipe OK"
                )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--live", action="store_true", help="also call the running app")
    parser.add_argument(
        "--configured-command",
        action="store_true",
        help="launch through the same uv command and environment used by Codex/Claude",
    )
    arguments = parser.parse_args()
    asyncio.run(run(arguments.live, arguments.configured_command))


if __name__ == "__main__":
    main()
