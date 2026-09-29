# Example agent workflow

Use an MCP-capable client with image support. This server supplies tools to the
client's model; it does not embed an LLM, train a model or implement RAG.

An example request to the client:

> Create a new rough-stone material. Inspect the available recipe and its parameter
> definitions first. Show two small preview variations, keep the original graph
> parameters unchanged during comparison, and wait for my choice before exporting.

The intended tool sequence is:

1. `material_maker_status`, then `list_materials` to establish app readiness and tab identity.
2. `list_material_recipes`, then `describe_material_recipe` to inspect available graph data.
3. `apply_material_recipe` with `create_new=true`; retain its returned `material_id`.
4. `get_material_graph` and `describe_node_type` to inspect actual node names and parameters.
5. `preview_material` or `preview_material_variations` using that material ID and
   values supported by the recipe/node description.
6. Inspect the returned images. After choosing the result, use `set_node_parameter`
   to apply it, discover `list_export_profiles`, then call `export_material` with a
   new output prefix and an explicit profile.
7. Read the returned manifest, rather than assuming a filename or that export succeeded.

For a custom graph, call `list_node_types` and `describe_node_type` before constructing
a fragment. Run `validate_graph_fragment`, inspect its errors, then apply the valid
fragment. Never invent node types, ports or parameter names.

`scripts/smoke_mcp.py --live` exercises a deterministic sequence over actual MCP
stdio calls. It proves tool integration for that sequence; it does not measure an
LLM's material quality or reliability on arbitrary natural-language requests.
