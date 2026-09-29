# Material Maker MCP

[![Host checks](https://github.com/Tigertycoon/material-maker-mcp/actions/workflows/check.yml/badge.svg)](https://github.com/Tigertycoon/material-maker-mcp/actions/workflows/check.yml)

**A Python MCP server and extended Godot bridge for agent-driven procedural material workflows.** An agent can inspect available nodes, validate a graph, build it, compare real 3D previews and export PBR maps with file hashes.

This is an integration project built on [Material Maker](https://github.com/RodZill4/material-maker) and [Daniel Schemann's original MCP bridge](https://github.com/schemann/material-maker-mcp). My contribution is the Python host and the bridge extensions described below, developed with AI coding assistance. [Origin and attribution](THIRD_PARTY_NOTICES.md).

## What the integration adds

| Problem | Implementation |
| --- | --- |
| Agents need discoverable operations | 35 typed MCP tools, node/parameter discovery and structured results |
| Generated graphs can contain invalid references | Fragment validation before applying an undoable batch of nodes |
| Two clients can race on application state | A shared FIFO queue on Godot's main loop, plus session-stable material IDs |
| A model needs to inspect the actual result | Real 3D viewport captures and labeled PBR maps returned as MCP images |
| Comparing variants should preserve the source | Bounded parameter sweeps with state restoration after success or reported failure |
| Exports need observable outcomes | Manifests with filenames, channels, sizes, hashes and changed-file state |

Ten declarative starter recipes cover clay, metal, ceramic, stone, brick, fabric and other foundations. Recipes use Material Maker's existing nodes and renderer. The server supplies tools to an external agent; it does not embed a language model or implement RAG.

## Quick start

Requires **Python 3.11+**, [uv](https://docs.astral.sh/uv/), Git and **Godot 4.7** with a working graphics device. The live application is tested on Windows. Host-only CI also runs on Linux. A standard Material Maker binary does not include this extended bridge.

From a clone of this repository:

```sh
uv sync --frozen --extra dev
uv run --frozen pytest -q
uv run --frozen python scripts/smoke_mcp.py
```

The last command verifies the MCP handshake and tool discovery without starting Material Maker.

Prepare a **separate** application checkout at the reviewed upstream revision:

```sh
git clone --no-checkout https://github.com/schemann/material-maker-mcp.git .runtime/material-maker
git -C .runtime/material-maker checkout 3a0a4bbd2662fd647f08767fe36d03024fd0d0c0
uv run --frozen python scripts/install_bridge.py .runtime/material-maker
```

The installer checks the commit and refuses to replace locally changed addon files. It does not patch application code. Use your Godot 4.7 executable in place of `godot` below:

```sh
godot --headless --editor --import --path .runtime/material-maker
godot --path .runtime/material-maker --no-splash --mcp-port=8767
```

Keep Material Maker running for live tool calls. The host and addon both default to port **8767**. If you already use Material Maker, see [setup and isolated testing](docs/setup.md) before sharing its settings or starting another instance.

## Connect an MCP client

For a client that accepts the common `mcpServers` JSON format, replace the repository path with your local clone:

```json
{
  "mcpServers": {
    "material-maker": {
      "command": "uv",
      "args": ["--directory", "/absolute/path/to/material-maker-mcp", "run", "--frozen", "material-maker-mcp"],
      "env": {
        "MATERIAL_MAKER_BRIDGE_HOST": "127.0.0.1",
        "MATERIAL_MAKER_BRIDGE_PORT": "8767",
        "MATERIAL_MAKER_BRIDGE_TIMEOUT": "240"
      }
    }
  }
}
```

Use an absolute path to `uv` if your client does not inherit PATH. On Windows, escape backslashes in JSON or use forward slashes.

Start with `material_maker_status` and `list_materials`, retain the material ID, discover a recipe or node definition, validate the graph and inspect a preview before exporting. See the [example agent workflow](docs/agent-workflow.md).

## Verification

```sh
uv run --frozen ruff check .
uv run --frozen pytest -q
uv run --frozen python scripts/smoke_mcp.py --configured-command --live
uv run --frozen python scripts/live_contracts.py
uv run --frozen python scripts/concurrency_gate.py
```

Live checks create disposable materials and output files: run them against a separate test instance, not a session with ongoing work. Set `MATERIAL_MAKER_BRIDGE_PORT` to match that instance. [Recorded results and limits](docs/validation.md).

## Scope

This is a local desktop integration, not a hosted service. The bridge has no authentication or filesystem sandbox; trusted clients can write to explicit paths with the app's permissions. A timeout does not cancel a mutation. Avoid manual edits during automation. [Architecture and trust boundary](docs/architecture.md).

The repository includes the Python host, addon, recipes and checks. Material Maker, Godot binaries and third-party material libraries are installed separately. MIT licensed; upstream attribution is retained.
