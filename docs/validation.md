# Validation record

Checked on **2026-09-29** against the source hashes in [validation.json](validation.json).

## Host and packaging

- Python **3.12.11** on Windows: **36 pytest cases passed**, Ruff lint and formatting passed.
- The tests cover real socket round trips, error propagation, request IDs, malformed
  envelopes/UTF-8, byte limits, configuration bounds, recipe copies/overrides, MCP
  annotations, temporary image embedding and refusing to overwrite modified addon files.
- A real stdio MCP handshake exposes **35 tools**, including structured results and
  image-returning tools. The configured-command check starts the actual `uv ... run`
  entrypoint rather than importing the server in the client process.
- Source distribution and Python wheel build successfully. The application/addon
  setup is included in the source distribution; the wheel contains the Python host
  and recipe catalog. Install the addon from the repository/source distribution.
- GitHub Actions repeats host checks on Windows and Linux with Python 3.11 and 3.13.
  It does not run the graphical Material Maker application.

## Live application

The final checks used a separate application checkout at
`3a0a4bbd2662fd647f08767fe36d03024fd0d0c0`, the published bridge **0.3.1**,
Material Maker **1.7**, Godot **4.7 stable**, and Vulkan on an AMD Radeon RX 6950 XT.
The application had its own user-data directory and TCP port.

- **Full MCP workflow:** discovery, explicit material IDs, fragment validation,
  batch creation, connections, parameter changes, duplication/removal, undo/redo,
  real 3D previews, state-restoring variations, save/load, recipe application and
  PBR export. Three exported files had their sizes and SHA-256 hashes independently
  checked; two PBR images were returned inline through MCP.
- **Failure contracts:** invalid fragment ports and enum values leave the graph
  unchanged. Invalid preview dimensions, model and output extension restore the
  previously active tab. A UTF-8 request split inside a multibyte character survives
  separate TCP reads.
- **Recipe catalog:** all ten recipes were validated, applied and rendered to
  128 × 128 PNGs. This establishes compatibility of the starter graphs, not artistic
  quality or production-ready materials.
- **Two-process queue:** independent Python hosts requested previews concurrently;
  both received valid 128 × 128 images for the intended material, the active tab
  was restored, and the bridge queue drained. This is a bounded concurrency check,
  not a throughput/load benchmark.
- The final application log contained **no GDScript errors** throughout those checks.

Compact output: [MCP smoke](evidence/live-smoke.txt), [live contracts](evidence/live-contracts.txt),
[concurrency](evidence/concurrency.txt).

## Observed application warnings and limits

The pinned upstream application logs Steam initialization errors when Steam is
unavailable, attempts an executable-relative HDR path before using its source
resource, and emits layout/HDR metadata warnings. Initial import also reports
missing MTL sidecars for optional meshes. These messages did not prevent the tested
sphere-preview workflows. This record does not claim a warning-free upstream app.

No live Linux/macOS application run, packaged application export, network service,
untrusted-client security audit, arbitrary-graph fuzzing, or LLM effectiveness
benchmark was performed. The library contains many more nodes and export profiles
than this bounded workflow exercises. Recovery after process crashes and manual UI
edits during automation are not covered.

Publication review corrected concrete issues found in the local integration:
final-chunk response size accounting, malformed response handling, fragmented
UTF-8, preview-error tab restoration, missing optional arguments, viewport stretch
handling and twelve recipe enum values. Enum inputs now require numeric option
indices across fragment creation, individual parameter edits and variation sweeps.
