# Setup and isolated testing

Use the exact upstream commit in the README with Godot 4.7. The addon depends on
Material Maker's internal graph and preview APIs; compatibility with newer upstream
versions is not assumed. No prebuilt application is bundled in this repository.

Godot imports the application assets before first launch. At the pinned upstream
revision, import can report missing `.mtl` sidecar files for optional Suzanne,
pillow and vase meshes. The sphere-preview workflow does not use those meshes.

## Keep test state separate

Use a fresh application checkout for the live checks. Before first launch, replace the existing custom-user-directory
settings under its `[application]` section in `project.godot`:

```ini
config/use_custom_user_dir=true
config/custom_user_dir_name="MaterialMakerMCPTest"
```

Use a unique name for each clean test run; do not leave the upstream
`config/custom_user_dir_name="material_maker_2"` setting in place. This keeps Material Maker's application settings and recent-file state separate
from the normal installation. Choose an unused TCP port, for example 18867:

```sh
godot --path .runtime/material-maker --no-splash --mcp-port=18867
```

Set the matching host environment in PowerShell:

```powershell
$env:MATERIAL_MAKER_BRIDGE_PORT = '18867'
$env:MATERIAL_MAKER_BRIDGE_TIMEOUT = '240'
uv run --frozen python scripts/smoke_mcp.py --configured-command --live
uv run --frozen python scripts/live_contracts.py
uv run --frozen python scripts/concurrency_gate.py
```

On a POSIX shell, use `export MATERIAL_MAKER_BRIDGE_PORT=18867` and
`export MATERIAL_MAKER_BRIDGE_TIMEOUT=240` instead. Host CI covers Linux; a live
Material Maker graphics session has only been verified on Windows for this release.

The smoke checks create material tabs and temporary exports. Do not run them in an
application session containing work you need to preserve. Close the disposable
application afterward; temporary file cleanup does not close its material tabs.

The optional PowerShell starter accepts explicit `-GodotPath`, `-ProjectPath` and
`-Port` parameters. It starts a hidden background instance for testing. Use the
direct Godot command when you want an interactive editor window.

## Troubleshooting

- **Bridge unavailable:** start the prepared application and match the app/host
  ports. A successful MCP handshake alone only proves host tool discovery.
- **Old tool list:** reconnect the MCP client after updating the Python host.
- **Unknown material ID:** list the current materials again; IDs last for one app session.
- **Preview update timeout:** inspect the application log and simplify the graph.
  Do not treat a timeout as cancellation of the original request.
- **Unexpected export files:** choose a fresh directory/prefix. Export manifests
  include existing matching files and report which ones changed.
- **Different upstream revision:** keep it in another checkout and review bridge
  compatibility before changing the installer's pin.
