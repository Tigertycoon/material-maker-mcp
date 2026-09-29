"""Typed stdio MCP server for Material Maker."""

from __future__ import annotations

import warnings
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Any

# MCP 1.29 currently triggers this narrow pydantic-settings forward-reference warning
# while defining its optional lifespan settings. It is harmless for a stdio server but
# otherwise pollutes every client startup and test run.
warnings.filterwarnings(
    "ignore",
    message=r"Field 'lifespan' has an incomplete definition:.*",
    module=r"pydantic_settings\.sources\.utils",
)

from mcp.server.fastmcp import FastMCP, Image  # noqa: E402
from mcp.types import ToolAnnotations  # noqa: E402

from .bridge import call_bridge  # noqa: E402
from .recipes import get_recipe, instantiate_recipe, list_recipes  # noqa: E402

READ_ONLY = ToolAnnotations(
    readOnlyHint=True, destructiveHint=False, idempotentHint=True, openWorldHint=False
)
MUTATING = ToolAnnotations(
    readOnlyHint=False, destructiveHint=False, idempotentHint=False, openWorldHint=False
)
IDEMPOTENT_MUTATION = ToolAnnotations(
    readOnlyHint=False, destructiveHint=False, idempotentHint=True, openWorldHint=False
)
DESTRUCTIVE = ToolAnnotations(
    readOnlyHint=False, destructiveHint=True, idempotentHint=False, openWorldHint=False
)

INSTRUCTIONS = """Operate Material Maker through its typed graph tools; never invent node names,
ports, parameters, or export profiles. Start with material_maker_status and list_materials. For a
new material, discover node types and call describe_node_type before building a fragment. Validate
larger fragments before applying them. Retain and pass material_id whenever more than one tab is
open. Use a curated recipe when it matches the requested foundation. Render or preview results
before saving/exporting. Do not issue parallel write operations."""

mcp = FastMCP("Material Maker", instructions=INSTRUCTIONS)


def _path(value: str) -> str:
    return str(Path(value).expanduser().resolve())


def _target(material_id: str) -> dict[str, str]:
    return {"material_id": material_id} if material_id else {}


@mcp.tool(annotations=READ_ONLY)
def material_maker_status() -> dict[str, Any]:
    """Check whether the bridge, Material Maker, and a material graph are ready."""
    return call_bridge("get_status")


@mcp.tool(annotations=READ_ONLY)
def material_maker_diagnostics() -> dict[str, Any]:
    """Return queue state, active operation timing, versions, and recent bridge errors."""
    return call_bridge("get_diagnostics")


@mcp.tool(annotations=READ_ONLY)
def list_bridge_actions() -> list[dict[str, Any]]:
    """List the internal bridge actions and their implementation status."""
    return call_bridge("list_actions")


@mcp.tool(annotations=READ_ONLY)
def list_materials() -> dict[str, Any]:
    """List open material tabs with stable session IDs, active state, and undo state."""
    return call_bridge("list_materials")


@mcp.tool(annotations=IDEMPOTENT_MUTATION)
def activate_material(material_id: str) -> dict[str, Any]:
    """Activate one material tab by an ID returned from list_materials."""
    return call_bridge("activate_material", material_id=material_id)


@mcp.tool(annotations=READ_ONLY)
def list_node_types(category: str = "", query: str = "", limit: int = 200) -> list[dict[str, Any]]:
    """List Material Maker node types, optionally filtered by category or text."""
    if limit < 1 or limit > 1000:
        raise ValueError("limit must be between 1 and 1000")
    items = call_bridge("list_node_types", category=category)
    if query:
        needle = query.casefold()
        items = [item for item in items if needle in str(item).casefold()]
    return items[:limit]


@mcp.tool(annotations=READ_ONLY)
def describe_node_type(name: str) -> dict[str, Any]:
    """Get ports, parameters, defaults, ranges, and documentation for a node type."""
    return call_bridge("describe_node_type", name=name)


@mcp.tool(annotations=READ_ONLY)
def get_material_graph(material_id: str = "") -> dict[str, Any]:
    """Return the current material graph, connections, parameters, and save path."""
    return call_bridge("get_graph", **_target(material_id))


@mcp.tool(annotations=READ_ONLY)
def get_material_node(node: str, material_id: str = "") -> dict[str, Any]:
    """Inspect a graph node, including ports and current parameter values."""
    return call_bridge("get_node", node=node, **_target(material_id))


@mcp.tool(annotations=MUTATING)
def new_material() -> dict[str, Any]:
    """Open a new material project with Material Maker's default PBR output node."""
    return call_bridge("new_material")


@mcp.tool(annotations=MUTATING)
def load_material(path: str) -> dict[str, Any]:
    """Load an existing .ptex material from an absolute or user-relative path."""
    return call_bridge("load_material", path=_path(path))


@mcp.tool(annotations=DESTRUCTIVE)
def save_material(path: str = "", material_id: str = "") -> dict[str, Any]:
    """Save the current material; omit path to reuse its existing .ptex path."""
    return call_bridge("save_material", path=_path(path) if path else "", **_target(material_id))


@mcp.tool(annotations=MUTATING)
def add_node(
    node_type: str,
    parameters: dict[str, Any] | None = None,
    position: list[float] | None = None,
    material_id: str = "",
) -> dict[str, Any]:
    """Add one node. Call describe_node_type first when ports or parameters are unknown."""
    return call_bridge(
        "add_node",
        type=node_type,
        parameters=parameters or {},
        position=position or [0, 0],
        **_target(material_id),
    )


@mcp.tool(annotations=MUTATING)
def add_graph_fragment(
    nodes: list[dict[str, Any]],
    connections: list[dict[str, Any]] | None = None,
    position: list[float] | None = None,
    material_id: str = "",
) -> dict[str, Any]:
    """Add up to 256 nodes and their internal connections in one undoable operation.

    Each node needs at least ``type`` and may include ``name``, ``parameters``, and
    ``node_position``. Connections use ``from``, ``from_port``, ``to``, and ``to_port``.
    """
    return call_bridge(
        "add_graph_fragment",
        nodes=nodes,
        connections=connections or [],
        position=position or [0, 0],
        **_target(material_id),
    )


@mcp.tool(annotations=READ_ONLY)
def validate_graph_fragment(
    nodes: list[dict[str, Any]],
    connections: list[dict[str, Any]] | None = None,
    material_id: str = "",
) -> dict[str, Any]:
    """Preflight a graph fragment without changing Material Maker."""
    return call_bridge(
        "validate_graph_fragment",
        nodes=nodes,
        connections=connections or [],
        **_target(material_id),
    )


@mcp.tool(annotations=DESTRUCTIVE)
def remove_node(node: str, material_id: str = "") -> dict[str, Any]:
    """Remove a node and all of its graph connections."""
    return call_bridge("remove_node", node=node, **_target(material_id))


@mcp.tool(annotations=IDEMPOTENT_MUTATION)
def move_node(node: str, position: list[float], material_id: str = "") -> dict[str, Any]:
    """Move a node to an absolute [x, y] graph position."""
    return call_bridge("move_node", node=node, position=position, **_target(material_id))


@mcp.tool(annotations=MUTATING)
def duplicate_node(
    node: str, position: list[float] | None = None, material_id: str = ""
) -> dict[str, Any]:
    """Duplicate one node; by default the copy is offset by 80 pixels."""
    arguments: dict[str, Any] = {"node": node}
    if position is not None:
        arguments["position"] = position
    arguments.update(_target(material_id))
    return call_bridge("duplicate_node", **arguments)


@mcp.tool(annotations=MUTATING)
def connect_nodes(
    from_node: str,
    from_port: int,
    to_node: str,
    to_port: int,
    material_id: str = "",
) -> dict[str, Any]:
    """Connect an output port to an input port after validating both indexes."""
    return call_bridge(
        "connect_nodes",
        **{
            "from": from_node,
            "from_port": from_port,
            "to": to_node,
            "to_port": to_port,
            **_target(material_id),
        },
    )


@mcp.tool(annotations=MUTATING)
def disconnect_nodes(
    from_node: str,
    from_port: int,
    to_node: str,
    to_port: int,
    material_id: str = "",
) -> dict[str, Any]:
    """Disconnect one exact graph connection."""
    return call_bridge(
        "disconnect_nodes",
        **{
            "from": from_node,
            "from_port": from_port,
            "to": to_node,
            "to_port": to_port,
            **_target(material_id),
        },
    )


@mcp.tool(annotations=IDEMPOTENT_MUTATION)
def set_node_parameter(node: str, name: str, value: Any, material_id: str = "") -> dict[str, Any]:
    """Set a validated node parameter and trigger Material Maker's update path."""
    return call_bridge("set_parameter", node=node, name=name, value=value, **_target(material_id))


@mcp.tool(annotations=READ_ONLY)
def get_node_parameter(node: str, name: str, material_id: str = "") -> dict[str, Any]:
    """Read one node parameter."""
    return call_bridge("get_parameter", node=node, name=name, **_target(material_id))


@mcp.tool(annotations=DESTRUCTIVE)
def render_node(
    node: str,
    path: str,
    output: int = 0,
    width: int = 512,
    height: int = 512,
    material_id: str = "",
) -> dict[str, Any]:
    """Render one node output to a PNG file; the destination directory must exist."""
    return call_bridge(
        "render_node",
        node=node,
        path=_path(path),
        output=output,
        size=[width, height],
        **_target(material_id),
    )


@mcp.tool(annotations=DESTRUCTIVE)
def save_material_preview(
    path: str,
    width: int = 512,
    height: int = 512,
    model: str = "sphere",
    rotation: list[float] | None = None,
    material_id: str = "",
) -> dict[str, Any]:
    """Save Material Maker's actual 3D PBR preview to a PNG file."""
    return call_bridge(
        "render_material_preview",
        path=_path(path),
        size=[width, height],
        model=model,
        rotation=rotation or [-15.0, 30.0, 0.0],
        **_target(material_id),
    )


@mcp.tool(annotations=READ_ONLY)
def preview_material(
    width: int = 512,
    height: int = 512,
    model: str = "sphere",
    rotation: list[float] | None = None,
    material_id: str = "",
) -> Image:
    """Return the live 3D PBR preview as MCP image content for visual inspection."""
    with TemporaryDirectory(prefix="material-maker-preview-") as temp_dir:
        preview_path = Path(temp_dir) / "preview.png"
        save_material_preview(str(preview_path), width, height, model, rotation, material_id)
        image_bytes = preview_path.read_bytes()
    return Image(data=image_bytes, format="png")


@mcp.tool(annotations=READ_ONLY)
def list_export_profiles(material_id: str = "") -> dict[str, Any]:
    """List export profiles supported by the current PBR material node."""
    return call_bridge("list_export_profiles", **_target(material_id))


@mcp.tool(annotations=DESTRUCTIVE)
def export_material(
    prefix: str, profile: str, size: int = 0, material_id: str = ""
) -> dict[str, Any]:
    """Export a material and return every output file with size, hash, and channel."""
    return call_bridge(
        "export_material",
        prefix=_path(prefix),
        profile=profile,
        size=size,
        **_target(material_id),
    )


@mcp.tool(annotations=READ_ONLY, structured_output=False)
def preview_material_maps(
    profile: str = "Godot/Godot 4 Standard",
    size: int = 256,
    material_id: str = "",
) -> list[Any]:
    """Export and return all PNG/JPEG/WebP PBR maps as labeled MCP images.

    The temporary export is deleted after its bytes have been embedded in the MCP response.
    Use export_material when persistent output files are required.
    """
    if size < 64 or size > 2048:
        raise ValueError("size must be between 64 and 2048")
    with TemporaryDirectory(prefix="material-maker-maps-") as temp_dir:
        result = export_material(str(Path(temp_dir) / "material"), profile, size, material_id)
        files = result.get("files", [])
        content: list[Any] = [
            {
                "profile": profile,
                "size": size,
                "material_id": result.get("material_id"),
                "files": [
                    {
                        key: item.get(key)
                        for key in (
                            "filename",
                            "channel",
                            "extension",
                            "size_bytes",
                            "sha256",
                        )
                    }
                    for item in files
                ],
            }
        ]
        image_count = 0
        for item in files:
            extension = str(item.get("extension", "")).lower()
            if extension not in {"png", "jpg", "jpeg", "webp"}:
                continue
            path = Path(str(item["path"]))
            image_format = "jpeg" if extension in {"jpg", "jpeg"} else extension
            content.extend(
                [
                    f"PBR map: {item.get('channel') or item.get('filename')}",
                    Image(data=path.read_bytes(), format=image_format),
                ]
            )
            image_count += 1
        if image_count == 0:
            raise RuntimeError(f"export profile {profile!r} produced no MCP-compatible images")
    return content


@mcp.tool(annotations=DESTRUCTIVE)
def render_material_variations(
    variations: dict[str, dict[str, list[Any]]],
    output_dir: str,
    mode: str = "preview",
    profile: str = "Godot/Godot 4 Standard",
    size: int = 256,
    model: str = "sphere",
    rotation: list[float] | None = None,
    material_id: str = "",
) -> dict[str, Any]:
    """Render up to 64 parameter combinations and restore the original graph state.

    ``variations`` maps node names to parameters and value lists, for example
    ``{"Noise": {"scale": [2.0, 4.0], "seed": [1, 2]}}``. Preview mode writes
    3D preview PNGs; export mode writes the selected profile and returns each manifest.
    """
    return call_bridge(
        "render_variations",
        variations=variations,
        output_dir=_path(output_dir),
        mode=mode,
        profile=profile,
        size=size,
        model=model,
        rotation=rotation or [-15.0, 30.0, 0.0],
        **_target(material_id),
    )


@mcp.tool(annotations=READ_ONLY, structured_output=False)
def preview_material_variations(
    variations: dict[str, dict[str, list[Any]]],
    size: int = 256,
    model: str = "sphere",
    rotation: list[float] | None = None,
    material_id: str = "",
) -> list[Any]:
    """Return safe parameter variations as labeled 3D MCP images without keeping files."""
    with TemporaryDirectory(prefix="material-maker-variations-") as temp_dir:
        result = render_material_variations(
            variations=variations,
            output_dir=temp_dir,
            mode="preview",
            size=size,
            model=model,
            rotation=rotation,
            material_id=material_id,
        )
        content: list[Any] = [
            {
                "material_id": result.get("material_id"),
                "combination_count": result.get("combination_count"),
                "state_restored": result.get("state_restored"),
                "variations": [
                    {"index": item.get("index"), "values": item.get("values")}
                    for item in result.get("results", [])
                ],
            }
        ]
        for item in result.get("results", []):
            path = Path(str(item["output"]["path"]))
            content.extend(
                [
                    f"Variation {item['index']}: {item['values']}",
                    Image(data=path.read_bytes(), format="png"),
                ]
            )
    return content


@mcp.tool(annotations=READ_ONLY)
def list_material_recipes(query: str = "", tag: str = "") -> list[dict[str, Any]]:
    """List the curated declarative starter recipes, optionally filtered by text or tag."""
    return list_recipes(query=query, tag=tag)


@mcp.tool(annotations=READ_ONLY)
def describe_material_recipe(recipe_id: str) -> dict[str, Any]:
    """Return one recipe's graph, parameters, connections, and suggested variations."""
    return get_recipe(recipe_id)


@mcp.tool(annotations=MUTATING)
def apply_material_recipe(
    recipe_id: str,
    create_new: bool = True,
    position: list[float] | None = None,
    material_id: str = "",
    overrides: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Validate and apply a curated recipe, optionally with constrained parameter overrides.

    Overrides use ``Node.parameter`` keys and may only target parameters already declared by
    the recipe. By default a fresh material tab is created to avoid replacing existing inputs.
    """
    if create_new and material_id:
        raise ValueError("material_id cannot be combined with create_new=true")
    recipe = instantiate_recipe(recipe_id, overrides)
    target_id = material_id
    if create_new:
        target_id = str(new_material()["material_id"])
    validation = validate_graph_fragment(recipe["nodes"], recipe["connections"], target_id)
    if not validation.get("valid"):
        raise RuntimeError(f"recipe {recipe_id!r} failed validation: {validation}")
    fragment = add_graph_fragment(
        recipe["nodes"],
        recipe["connections"],
        position or [0.0, 0.0],
        target_id,
    )
    return {
        "recipe_id": recipe_id,
        "title": recipe["title"],
        "material_id": target_id,
        "created_new_material": create_new,
        "validation": validation,
        "nodes": fragment.get("nodes", []),
        "recommended_variations": recipe.get("recommended_variations", {}),
    }


@mcp.tool(annotations=MUTATING)
def undo(material_id: str = "") -> dict[str, Any]:
    """Undo one operation in the selected or active material."""
    return call_bridge("undo", **_target(material_id))


@mcp.tool(annotations=MUTATING)
def redo(material_id: str = "") -> dict[str, Any]:
    """Redo one operation in the selected or active material."""
    return call_bridge("redo", **_target(material_id))


def main() -> None:
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
