# Origin and attribution

This repository packages a Python MCP host and an extended Godot addon. It does not
contain or claim authorship of the Material Maker application, rendering engine,
node library or MCP protocol/SDK.

| Component | Origin | Contribution here |
| --- | --- | --- |
| Material Maker | [Rodolphe Suescun and contributors](https://github.com/RodZill4/material-maker), MIT | External application dependency; not redistributed here |
| Original MCP bridge | [Daniel Schemann's fork](https://github.com/schemann/material-maker-mcp/tree/3a0a4bbd2662fd647f08767fe36d03024fd0d0c0/addons/mcp_bridge), MIT | The addon in this repo is derived from that implementation |
| Python host, recipes and bridge extensions | Niklas Schmitt / Tigertycoon, developed with AI coding assistance | Typed MCP tools, client serialization, session material IDs, graph-fragment validation, previews, state-restoring variations, diagnostics and hashed export manifests |
| MCP Python SDK | [Model Context Protocol Python SDK](https://github.com/modelcontextprotocol/python-sdk), MIT | External dependency installed through the lockfile |
| Godot | [Godot Engine](https://godotengine.org/license/), MIT | External engine required to run the application |

The reviewed application/bridge baseline is **schemann/material-maker-mcp commit
`3a0a4bbd2662fd647f08767fe36d03024fd0d0c0`**. Its original license is reproduced
unchanged in [UPSTREAM-LICENSE.md](UPSTREAM-LICENSE.md).

The upstream bridge already provided the TCP transport, application menus,
preferences, node discovery and basic graph operations. The extensions above build
on that work. The host and modified addon were extracted from an existing local
integration; this repository's initial commit is a publication snapshot, not a
reconstruction of the original development history.

Publication changes include portable setup, a consistent port default, protocol
edge-case handling, UTF-8 framing, tab restoration on preview errors, regression
checks and documentation. Dependency packages retain their own licenses; the
application's libraries and assets are downloaded from upstream separately.
