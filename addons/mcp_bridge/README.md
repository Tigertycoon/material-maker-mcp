# Material Maker MCP Bridge 0.3.1

Self-contained Material Maker addon for a typed external MCP host:

```text
Material Maker <-- JSON-lines TCP on loopback --> Python MCP host <-- stdio --> client
```

The addon is an autoload and does not modify Material Maker's application code. It injects
an MCP menu and Preferences tab for autostart, port, status, and version information. Values
are stored through Material Maker's existing `mm_globals.config` mechanism.

## Protocol and scheduling

The TCP server listens only on `127.0.0.1:8767`; `--mcp-port=<port>` overrides the port.
Each line is one JSON object:

- Request: `{ "action": "...", "args": {...}, "id": <optional> }`
- Success: `{ "ok": true, "result": ..., "duration_msec": ..., "id": ... }`
- Failure: `{ "ok": false, "error": "...", "code": "...", "possible_solutions": [...], "details": {...}, "id": ... }`

All requests enter one bridge-wide FIFO queue and execute on Godot's main loop. This also
serializes independent host processes, so two connected MCP clients cannot mutate Material
Maker concurrently. Diagnostics expose the current action, elapsed time, queue depth, client
count, versions, and the last 20 structured failures.

## Capabilities

Discovery and diagnostics:

- `ping`, `version`, `get_status`, `get_diagnostics`
- `list_actions`, `describe`, `list_node_types`, `describe_node_type`

Materials and graphs:

- `list_materials`, `activate_material`, `new_material`, `load_material`, `save_material`
- `get_graph`, `get_node`, `get_parameter`, `set_parameter`
- `validate_graph_fragment`, `add_graph_fragment`
- `add_node`, `duplicate_node`, `remove_node`, `move_node`
- `connect_nodes`, `disconnect_nodes`, `undo`, `redo`

Visual output:

- `render_node`
- `render_material_preview`: captures the real Preview3D viewport at an exact requested size,
  waits for only the target graph's shader/dependency buffers, and restores model, transform,
  viewport settings, preview material, and previously active tab.
- `list_export_profiles`, `export_material`: returns every prefix-matching file with channel,
  extension, byte size, modification time, SHA-256, and whether it changed.
- `render_variations`: sweeps parameter value lists in preview or export mode, caps the
  Cartesian product at 64, and restores original values, dirty state, and active tab.

Stable `material-N` IDs identify open tabs for the lifetime of the application process.
Graph fragments are dry-run validated for node types, aliases, parameters, port indexes,
references, and cycles before mutation. Batch creation is capped at 256 nodes.

## Trust boundary

The bridge exposes only registered material operations. It has no arbitrary GDScript,
Python, shell, or unrestricted file-evaluation action. Request size is capped at 8 MiB and
the server is loopback-only. It has no authentication or filesystem sandbox; see
[the full trust boundary](../../docs/architecture.md#trust-boundary).

## Adding an action

Register a typed handler in `_register_actions()` and return `_error(...)` for failures:

```gdscript
register_action("my_action", _action_my_action, "Short description.",
    [ { name = "some_arg", type = "string", required = true } ])

func _action_my_action(args : Dictionary):
    if not args.has("some_arg"):
        return _error("missing argument 'some_arg'", "invalid_arguments")
    return { result = args.some_arg }
```

The Python host in this repository owns MCP SDK
packaging, client configuration, typed tools, temporary image embedding, and recipes. Keeping
that layer separate prevents MCP dependency changes from entering Material Maker's core.
