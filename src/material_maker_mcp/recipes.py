"""Curated, declarative starter recipes for Material Maker."""

from __future__ import annotations

import json
from copy import deepcopy
from functools import lru_cache
from importlib.resources import files
from typing import Any


@lru_cache(maxsize=1)
def _catalog() -> tuple[dict[str, Any], ...]:
    path = files("material_maker_mcp").joinpath("recipes.json")
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, list) or not data:
        raise RuntimeError("recipe catalog must be a non-empty JSON array")
    required = {"id", "title", "description", "tags", "nodes", "connections"}
    ids: set[str] = set()
    for recipe in data:
        if not isinstance(recipe, dict) or not required <= recipe.keys():
            raise RuntimeError("every recipe must contain its metadata and graph fragment")
        recipe_id = str(recipe["id"])
        if recipe_id in ids:
            raise RuntimeError(f"duplicate recipe id: {recipe_id}")
        ids.add(recipe_id)
        if not recipe["nodes"]:
            raise RuntimeError(f"recipe {recipe_id!r} contains no nodes")
    return tuple(data)


def list_recipes(query: str = "", tag: str = "") -> list[dict[str, Any]]:
    """Return compact copies of matching catalog entries."""
    needle = query.casefold().strip()
    normalized_tag = tag.casefold().strip()
    result: list[dict[str, Any]] = []
    for recipe in _catalog():
        searchable = " ".join(
            [recipe["id"], recipe["title"], recipe["description"], *recipe["tags"]]
        ).casefold()
        tags = {str(value).casefold() for value in recipe["tags"]}
        if needle and needle not in searchable:
            continue
        if normalized_tag and normalized_tag not in tags:
            continue
        result.append(
            {
                "id": recipe["id"],
                "title": recipe["title"],
                "description": recipe["description"],
                "tags": list(recipe["tags"]),
                "node_count": len(recipe["nodes"]),
                "recommended_variations": deepcopy(recipe.get("recommended_variations", {})),
            }
        )
    return result


def get_recipe(recipe_id: str) -> dict[str, Any]:
    """Return a deep copy of one recipe."""
    for recipe in _catalog():
        if recipe["id"] == recipe_id:
            return deepcopy(recipe)
    available = ", ".join(recipe["id"] for recipe in _catalog())
    raise ValueError(f"unknown recipe {recipe_id!r}; available: {available}")


def instantiate_recipe(recipe_id: str, overrides: dict[str, Any] | None = None) -> dict[str, Any]:
    """Apply constrained ``Node.parameter`` overrides to a copied recipe."""
    recipe = get_recipe(recipe_id)
    by_name = {str(node["name"]): node for node in recipe["nodes"]}
    for target, value in (overrides or {}).items():
        node_name, separator, parameter = target.partition(".")
        if not separator or not node_name or not parameter:
            raise ValueError(f"override {target!r} must use Node.parameter syntax")
        node = by_name.get(node_name)
        if node is None:
            raise ValueError(f"override references unknown recipe node {node_name!r}")
        parameters = node.get("parameters", {})
        if parameter not in parameters:
            raise ValueError(
                f"override references undeclared parameter {parameter!r} on {node_name!r}"
            )
        parameters[parameter] = deepcopy(value)
    return recipe
