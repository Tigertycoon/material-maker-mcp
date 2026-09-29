from __future__ import annotations

import pytest

from material_maker_mcp import recipes, server


def test_curated_recipe_catalog_is_unique_and_complete():
    catalog = recipes.list_recipes()
    assert len(catalog) == 10
    assert len({item["id"] for item in catalog}) == len(catalog)
    assert all(item["node_count"] >= 2 for item in catalog)
    assert all(item["recommended_variations"] for item in catalog)


def test_recipe_override_is_constrained_and_does_not_mutate_catalog():
    changed = recipes.instantiate_recipe("matte_clay", {"RCP_Clay_Roughness.color": 0.5})
    original = recipes.get_recipe("matte_clay")
    assert changed["nodes"][1]["parameters"]["color"] == 0.5
    assert original["nodes"][1]["parameters"]["color"] == 0.82
    with pytest.raises(ValueError, match="undeclared parameter"):
        recipes.instantiate_recipe("matte_clay", {"RCP_Clay_Roughness.seed": 3})


def test_apply_recipe_validates_before_mutating_graph(monkeypatch):
    calls = []
    monkeypatch.setattr(server, "new_material", lambda: {"material_id": "material-recipe"})

    def fake_validate(nodes, connections, material_id):
        calls.append(("validate", material_id, len(nodes), len(connections)))
        return {"valid": True}

    def fake_add(nodes, connections, position, material_id):
        calls.append(("add", material_id, position))
        return {"nodes": nodes}

    monkeypatch.setattr(server, "validate_graph_fragment", fake_validate)
    monkeypatch.setattr(server, "add_graph_fragment", fake_add)
    result = server.apply_material_recipe("polished_metal")
    assert result["material_id"] == "material-recipe"
    assert calls[0][0] == "validate"
    assert calls[1] == ("add", "material-recipe", [0.0, 0.0])


def test_recipe_tools_are_read_only_until_apply():
    list_tool = server.mcp._tool_manager.get_tool("list_material_recipes")
    describe_tool = server.mcp._tool_manager.get_tool("describe_material_recipe")
    apply_tool = server.mcp._tool_manager.get_tool("apply_material_recipe")
    assert list_tool is not None and list_tool.annotations.readOnlyHint is True
    assert describe_tool is not None and describe_tool.annotations.readOnlyHint is True
    assert apply_tool is not None and apply_tool.annotations.readOnlyHint is False
