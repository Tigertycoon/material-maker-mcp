extends Node
## MCP bridge for Material Maker.
##
## Runs a small JSON-lines TCP server on localhost so an external MCP host
## process (see mcp_bridge_host) can remote-control the app.
## Protocol: one JSON object per line, both directions.
##   Request:  { "action": "...", "args": {...}, "id": <optional> }
##   Response: { "ok": true, "result": ... } or { "ok": false, "error": "..." }
##
## This addon is intentionally self-contained: the only core change it needs
## is one autoload line in project.godot.

const DEFAULT_PORT : int = 8767
const HOST : String = "127.0.0.1"
const BRIDGE_VERSION : String = "0.3.1"
const PROTOCOL_VERSION : int = 2
const LIBRARY_PATH : String = "res://material_maker/library/base.json"
const MAX_REQUEST_BYTES : int = 8 * 1024 * 1024
const MAX_BATCH_NODES : int = 256
const MAX_VARIATION_COMBINATIONS : int = 64
const MAX_RECENT_ERRORS : int = 20

var server : TCPServer
# Array of { peer: StreamPeerTCP, buffer: PackedByteArray }
var clients : Array = []
var actions : Dictionary = {}
var pending_requests : Array[Dictionary] = []
var request_active : bool = false
var active_action : String = ""
var active_action_started_msec : int = 0
var recent_errors : Array[Dictionary] = []
var next_material_id : int = 1

var menu_button : MenuButton
var status_item_id : int = -1

# macOS global menu (DisplayServer) support
const GLOBAL_MENU : String = "_main/MCP"
var using_global_menu : bool = false
var global_menu_main_count : int = -1
var global_enabled_index : int = -1
var global_status_index : int = -1
var menu_guard_elapsed : float = 0.0

var current_port : int = 0


func _ready() -> void:
	_register_actions()
	if is_autostart_enabled():
		start_server(get_port())
	_inject_menu()


func _exit_tree() -> void:
	stop_server()


func get_port() -> int:
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--mcp-port="):
			return int(arg.trim_prefix("--mcp-port="))
	if mm_globals.has_config("mcp_bridge_port"):
		return int(mm_globals.get_config("mcp_bridge_port"))
	return DEFAULT_PORT


func is_autostart_enabled() -> bool:
	if mm_globals.has_config("mcp_bridge_autostart"):
		return bool(mm_globals.get_config("mcp_bridge_autostart"))
	return true


# --- Action registry ---------------------------------------------------------

func register_action(action_name : String, handler : Callable, description : String = "", args_doc : Array = []) -> void:
	actions[action_name] = {
		handler = handler,
		description = description,
		args = args_doc,
	}


func _register_actions() -> void:
	register_action("ping", _action_ping, "Check that the bridge is alive.")
	register_action("version", _action_version, "Get Material Maker / Godot / bridge version info.")
	register_action("get_status", _action_get_status, "Get bridge, application and current material readiness.")
	register_action("get_diagnostics", _action_get_diagnostics,
			"Get queue state and recent bridge failures without mutating Material Maker.")

	# --- Documentation interface -------------------------------------------------
	register_action("list_actions", _action_list_actions,
			"List all bridge actions with argument signatures, descriptions and implementation status.")
	register_action("describe", _action_describe,
			"Documentation entry point. topic: actions | action (name=...) | node_types (category=...) | node_type (name=...).",
			[ { name = "topic", type = "string", required = true }, { name = "name", type = "string" }, { name = "category", type = "string" } ])
	register_action("list_node_types", _action_list_node_types,
			"List material node types from the library, with category paths.",
			[ { name = "category", type = "string", description = "Optional category prefix filter, e.g. 'Noise'" } ])
	register_action("describe_node_type", _action_describe_node_type,
			"Full documentation of one node type: parameters (type, default, range, enum values), inputs, outputs, descriptions.",
			[ { name = "name", type = "string", required = true } ])

	# --- Material tools ------------------------------------------------------------
	# All of these operate on the current project's data layer via
	#   mm_globals.main_window.get_current_graph_edit() -> MMGraphEdit
	#     (material_maker/panels/graph_edit/graph_edit.gd)
	register_action("list_materials", _action_list_materials,
			"List open material tabs with session-stable IDs and active/dirty state.")
	register_action("activate_material", _action_activate_material,
			"Activate an open material tab by its session-stable ID.",
			[ { name = "material_id", type = "string", required = true } ])
	register_action("get_graph", _action_get_graph,
			"Serialize the current material graph (nodes, connections, parameters).")
	register_action("get_node", _action_get_node,
			"Inspect one node, including position, ports, parameter definitions and current values.",
			[ { name = "node", type = "string", required = true } ])
	register_action("new_material", _action_new_material,
			"Open a new empty material project tab.")
	register_action("load_material", _action_load_material,
			"Load a .ptex material from disk into a project tab.",
			[ { name = "path", type = "string", required = true } ])
	register_action("save_material", _action_save_material,
			"Save the current material to disk.",
			[ { name = "path", type = "string" } ])
	register_action("add_node", _action_add_node,
			"Create a node of a given type in the current graph.",
			[ { name = "type", type = "string", required = true }, { name = "parameters", type = "object" }, { name = "position", type = "array" } ])
	register_action("add_graph_fragment", _action_add_graph_fragment,
			"Create several nodes and their internal connections in one undoable operation.",
			[ { name = "nodes", type = "array", required = true }, { name = "connections", type = "array" }, { name = "position", type = "array" } ])
	register_action("validate_graph_fragment", _action_validate_graph_fragment,
			"Validate node types, aliases, parameters, ports, references and cycles without changing the graph.",
			[ { name = "nodes", type = "array", required = true }, { name = "connections", type = "array" } ])
	register_action("remove_node", _action_remove_node,
			"Remove a node from the current graph.",
			[ { name = "node", type = "string", required = true } ])
	register_action("move_node", _action_move_node,
			"Move a node to an absolute graph position.",
			[ { name = "node", type = "string", required = true }, { name = "position", type = "array", required = true } ])
	register_action("duplicate_node", _action_duplicate_node,
			"Duplicate a node and optionally place the copy at an absolute graph position.",
			[ { name = "node", type = "string", required = true }, { name = "position", type = "array" } ])
	register_action("connect_nodes", _action_connect_nodes,
			"Connect an output port of one node to an input port of another.",
			[ { name = "from", type = "string", required = true }, { name = "from_port", type = "int", required = true },
			  { name = "to", type = "string", required = true }, { name = "to_port", type = "int", required = true } ])
	register_action("disconnect_nodes", _action_disconnect_nodes,
			"Remove a connection between two nodes.",
			[ { name = "from", type = "string", required = true }, { name = "from_port", type = "int" },
			  { name = "to", type = "string", required = true }, { name = "to_port", type = "int" } ])
	register_action("set_parameter", _action_set_parameter,
			"Set a parameter of a node (triggers re-render).",
			[ { name = "node", type = "string", required = true }, { name = "name", type = "string", required = true }, { name = "value", required = true } ])
	register_action("get_parameter", _action_get_parameter,
			"Get a parameter value of a node.",
			[ { name = "node", type = "string", required = true }, { name = "name", type = "string", required = true } ])
	register_action("render_node", _action_render_node,
			"Render one output of a node to an image file, return the file path.",
			[ { name = "node", type = "string", required = true }, { name = "output", type = "int" },
			  { name = "size", type = "array", description = "[width, height], default [512, 512]" },
			  { name = "path", type = "string", required = true } ])
	register_action("render_material_preview", _action_render_material_preview,
			"Render Material Maker's real 3D PBR preview to a PNG file.",
			[ { name = "path", type = "string", required = true },
			  { name = "size", type = "array", description = "[width, height], default [512, 512]" },
			  { name = "model", type = "string", description = "current|cube|cylinder|sphere|plane|prism" },
			  { name = "rotation", type = "array", description = "Optional [x, y, z] degrees" },
			  { name = "material_id", type = "string" } ])
	register_action("export_material", _action_export_material,
			"Export the current material and return a complete, hashed file manifest.",
			[ { name = "prefix", type = "string", required = true }, { name = "profile", type = "string", required = true },
			  { name = "size", type = "int" }, { name = "material_id", type = "string" } ])
	register_action("list_export_profiles", _action_list_export_profiles,
			"List export profiles available on the current material node.")
	register_action("undo", _action_undo,
			"Undo one operation in a material tab.",
			[ { name = "material_id", type = "string" } ])
	register_action("redo", _action_redo,
			"Redo one operation in a material tab.",
			[ { name = "material_id", type = "string" } ])

	register_action("render_variations", _action_render_variations,
			"Safely sweep parameter lists, render/export every combination, and restore all original values.",
			[ { name = "variations", type = "object", required = true, description = "{ node: { param: [v1, v2, ...] } }" },
			  { name = "output_dir", type = "string", required = true },
			  { name = "mode", type = "string", description = "preview (default) or export" },
			  { name = "profile", type = "string", description = "Required in export mode" },
			  { name = "model", type = "string", description = "3D model in preview mode" },
			  { name = "size", type = "int" }, { name = "material_id", type = "string" } ])


func _action_ping(_args : Dictionary) -> Dictionary:
	return { pong = true }


func _action_version(_args : Dictionary) -> Dictionary:
	return {
		app = "Material Maker",
		app_version = ProjectSettings.get_setting("application/config/actual_release", ""),
		godot_version = Engine.get_version_info().string,
		bridge_version = BRIDGE_VERSION,
		protocol_version = PROTOCOL_VERSION,
	}


func _action_not_implemented(_args : Dictionary) -> Dictionary:
	return _error("not implemented yet (skeleton, see TODO in addons/mcp_bridge/mcp_bridge.gd)")


# --- Material tools ---------------------------------------------------------------
# Data layer anchors: MMGraphEdit (material_maker/panels/graph_edit/graph_edit.gd),
# MMGenGraph / MMGenBase (addons/material_maker/engine/nodes/), MMLoader (loader.gd).

func _get_projects():
	if mm_globals.main_window == null or mm_globals.main_window.projects_panel == null:
		return null
	return mm_globals.main_window.projects_panel.get_projects()


func _material_id_for(graph_edit) -> String:
	if graph_edit == null:
		return ""
	if not graph_edit.has_meta("mcp_material_id"):
		graph_edit.set_meta("mcp_material_id", "material-%d" % next_material_id)
		next_material_id += 1
	return str(graph_edit.get_meta("mcp_material_id"))


func _material_tab_entries() -> Array[Dictionary]:
	var projects = _get_projects()
	var result : Array[Dictionary] = []
	if projects == null:
		return result
	for index in range(projects.get_tab_count()):
		var tab = projects.get_child(index)
		if tab == null or not tab.has_method("get_graph_edit"):
			continue
		var graph_edit = tab.get_graph_edit()
		if graph_edit == null or not graph_edit.has_method("get_project_type") or graph_edit.get_project_type() != "material":
			continue
		result.append({ index = index, tab = tab, graph_edit = graph_edit })
	return result


func _material_summary(entry : Dictionary, active_index : int) -> Dictionary:
	var graph_edit = entry.graph_edit
	return {
		material_id = _material_id_for(graph_edit),
		tab_index = entry.index,
		active = entry.index == active_index,
		save_path = graph_edit.save_path,
		dirty = graph_edit.need_save,
		node_count = graph_edit.generator.get_child_count() if graph_edit.generator != null else 0,
		can_undo = graph_edit.undoredo != null and graph_edit.undoredo.can_undo(),
		can_redo = graph_edit.undoredo != null and graph_edit.undoredo.can_redo(),
	}


func _find_material_entry(material_id : String) -> Dictionary:
	var projects = _get_projects()
	if projects == null:
		return {}
	if material_id == "":
		var current = mm_globals.main_window.get_current_graph_edit()
		for entry in _material_tab_entries():
			if entry.graph_edit == current:
				return entry
		return {}
	for entry in _material_tab_entries():
		if _material_id_for(entry.graph_edit) == material_id:
			return entry
	return {}


func _get_graph_edit(args : Dictionary = {}, activate : bool = true):
	var material_id : String = str(args.get("material_id", ""))
	var entry := _find_material_entry(material_id)
	if entry.is_empty():
		return null
	if activate:
		var projects = _get_projects()
		if projects != null and projects.current_tab != entry.index:
			projects.current_tab = entry.index
	return entry.graph_edit


func _get_generator(graph_edit, node_name : String):
	if graph_edit == null or graph_edit.generator == null:
		return null
	return graph_edit.generator.get_node_or_null(NodePath(node_name))


func _get_ui_node(graph_edit, node_name : String):
	if graph_edit == null:
		return null
	return graph_edit.get_node_or_null(NodePath("node_"+node_name))


func _vector2_arg(args : Dictionary, key : String, default_value : Vector2) -> Vector2:
	var value = args.get(key, null)
	if value is Array and value.size() == 2:
		return Vector2(float(value[0]), float(value[1]))
	return default_value


func _json_value(value):
	if value is Dictionary:
		var result : Dictionary = {}
		for key in value.keys():
			result[str(key)] = _json_value(value[key])
		return result
	if value is Array:
		var result : Array = []
		for item in value:
			result.append(_json_value(item))
		return result
	if value is Vector2:
		return [value.x, value.y]
	return MMType.serialize_value(value)


func _node_details(gen) -> Dictionary:
	var values : Dictionary = {}
	for parameter_def in gen.get_parameter_defs():
		if parameter_def.has("name"):
			values[parameter_def.name] = _json_value(gen.get_parameter(parameter_def.name))
	return {
		name = gen.name,
		type = gen.model if gen.model != null else gen.get_type(),
		position = [gen.position.x, gen.position.y],
		parameters = values,
		parameter_defs = _json_value(gen.get_parameter_defs()),
		inputs = _json_value(gen.get_input_defs()),
		outputs = _json_value(gen.get_output_defs()),
	}


func _action_get_status(_args : Dictionary) -> Dictionary:
	var app_ready : bool = mm_globals.main_window != null
	var graph_edit = _get_graph_edit({}, false) if app_ready else null
	return {
		bridge_ready = is_running(),
		app_ready = app_ready,
		material_open = graph_edit != null and graph_edit.top_generator != null,
		active_material_id = _material_id_for(graph_edit),
		save_path = graph_edit.save_path if graph_edit != null else "",
		port = current_port,
		client_count = clients.size(),
		queue_depth = pending_requests.size(),
		busy = request_active,
		active_action = active_action,
		active_action_elapsed_msec = Time.get_ticks_msec() - active_action_started_msec if request_active else 0,
		recent_error_count = recent_errors.size(),
		version = _action_version({}),
	}


func _action_get_diagnostics(_args : Dictionary) -> Dictionary:
	return {
		queue_depth = pending_requests.size(),
		busy = request_active,
		active_action = active_action,
		active_action_elapsed_msec = Time.get_ticks_msec() - active_action_started_msec if request_active else 0,
		clients = clients.size(),
		recent_errors = recent_errors.duplicate(true),
		version = _action_version({}),
	}


func _action_list_materials(_args : Dictionary) -> Dictionary:
	var projects = _get_projects()
	if projects == null:
		return _error("main window not ready", "app_not_ready", ["Wait for Material Maker to finish starting"])
	var materials : Array = []
	for entry in _material_tab_entries():
		materials.append(_material_summary(entry, projects.current_tab))
	return { materials = materials, active_material_id = _material_id_for(_get_graph_edit({}, false)) }


func _action_activate_material(args : Dictionary):
	var material_id : String = str(args.get("material_id", ""))
	if material_id == "":
		return _error("missing 'material_id'", "invalid_arguments", ["Call list_materials and pass one of its material_id values"])
	var entry := _find_material_entry(material_id)
	if entry.is_empty():
		return _error("unknown material_id '%s'" % material_id, "material_not_found", ["Call list_materials to refresh the open material IDs"])
	var projects = _get_projects()
	projects.current_tab = entry.index
	return _material_summary(entry, projects.current_tab)


func _validate_port(gen, port : int, output : bool) -> String:
	var definitions : Array = gen.get_output_defs() if output else gen.get_input_defs()
	if port < 0 or port >= definitions.size():
		return "%s port %d is out of range (available: 0..%d)" % ["output" if output else "input", port, definitions.size()-1]
	return ""


func _action_get_graph(args : Dictionary):
	var graph_edit = _get_graph_edit(args, false)
	if graph_edit == null or graph_edit.top_generator == null:
		return _error("no material project open")
	return {
		save_path = graph_edit.save_path,
		graph = _json_value(graph_edit.top_generator.serialize()),
	}


func _action_get_node(args : Dictionary):
	var graph_edit = _get_graph_edit(args, false)
	var gen = _get_generator(graph_edit, str(args.get("node", "")))
	if gen == null:
		return _error("unknown node '%s'" % str(args.get("node", "")))
	return _node_details(gen)


func _action_new_material(_args : Dictionary):
	if mm_globals.main_window == null:
		return _error("main window not ready")
	mm_globals.main_window.new_material()
	for _frame in 120:
		var graph_edit = _get_graph_edit({}, false)
		if graph_edit != null and graph_edit.top_generator != null:
			return { created = true, material_id = _material_id_for(graph_edit), graph = _json_value(graph_edit.top_generator.serialize()) }
		await get_tree().process_frame
	return _error("material project creation timed out")


func _action_load_material(args : Dictionary):
	if mm_globals.main_window == null:
		return _error("main window not ready")
	var path : String = str(args.get("path", ""))
	if path == "":
		return _error("missing 'path'")
	if path.get_extension().to_lower() != "ptex":
		return _error("material path must end in .ptex")
	if not FileAccess.file_exists(path):
		return _error("material file does not exist: '%s'" % path)
	var graph_edit = mm_globals.main_window.create_new_graph_edit_if_needed()
	if graph_edit == null or not await graph_edit.load_file(path):
		return _error("failed to load '%s'" % path)
	return { loaded = path, material_id = _material_id_for(graph_edit), graph = _json_value(graph_edit.top_generator.serialize()) }


func _action_save_material(args : Dictionary):
	var graph_edit = _get_graph_edit(args)
	if graph_edit == null:
		return _error("no material project open")
	var path : String = str(args.get("path", ""))
	if path == "":
		path = graph_edit.save_path
	if path == "":
		return _error("no path given and the project has no save path")
	if path.get_extension().to_lower() != "ptex":
		return _error("material path must end in .ptex")
	if not await graph_edit.save_file(path):
		return _error("save failed")
	return { saved = path }


func _action_add_node(args : Dictionary):
	var graph_edit = _get_graph_edit(args)
	if graph_edit == null:
		return _error("no material project open")
	var type_name : String = str(args.get("type", ""))
	if type_name == "":
		return _error("missing 'type'")
	var data : Dictionary = { type = type_name, parameters = args.get("parameters", {}) }
	var validation : Dictionary = await _action_validate_graph_fragment({
		nodes = [data], material_id = str(args.get("material_id", ""))
	})
	if not validation.valid:
		return _error("node validation failed", "validation_failed", [], { validation = validation })
	var position := _vector2_arg(args, "position", Vector2(0, 0))
	var nodes : Array = await graph_edit.create_nodes(data, position)
	if nodes.is_empty():
		return _error("failed to create node of type '%s'" % type_name)
	return _node_details(nodes[0].generator)


func _action_add_graph_fragment(args : Dictionary):
	var graph_edit = _get_graph_edit(args)
	if graph_edit == null:
		return _error("no material project open")
	var validation : Dictionary = await _action_validate_graph_fragment(args)
	if not validation.valid:
		return _error(
				"graph fragment validation failed",
				"validation_failed",
				["Call validate_graph_fragment and correct every reported error"],
				{ validation = validation })
	var nodes = args.get("nodes", null)
	var connections = args.get("connections", [])
	var created : Array = await graph_edit.create_nodes(
			{ nodes = nodes.duplicate(true), connections = connections.duplicate(true) },
			_vector2_arg(args, "position", Vector2(0, 0)))
	if created.is_empty():
		return _error("no nodes were created")
	var result : Array = []
	for ui_node in created:
		result.append(_node_details(ui_node.generator))
	return { nodes = result, graph = _json_value(graph_edit.top_generator.serialize()), validation = validation }


func _graph_has_cycle(adjacency : Dictionary) -> bool:
	var visiting : Dictionary = {}
	var visited : Dictionary = {}
	for node_name in adjacency.keys():
		if _graph_cycle_visit(str(node_name), adjacency, visiting, visited):
			return true
	return false


func _graph_cycle_visit(node_name : String, adjacency : Dictionary, visiting : Dictionary, visited : Dictionary) -> bool:
	if visiting.has(node_name):
		return true
	if visited.has(node_name):
		return false
	visiting[node_name] = true
	for next_name in adjacency.get(node_name, []):
		if _graph_cycle_visit(str(next_name), adjacency, visiting, visited):
			return true
	visiting.erase(node_name)
	visited[node_name] = true
	return false


func _parameter_validation_error(generator, parameter_name : String, value) -> String:
	var definition : Dictionary = generator.get_parameter_def(parameter_name)
	if definition.is_empty() and not generator.parameters.has(parameter_name):
		return "unknown parameter '%s'" % parameter_name
	if definition.get("type", "") == "enum":
		var options : Array = definition.get("values", [])
		if (typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT
				or not is_finite(float(value)) or float(value) < 0
				or float(value) >= options.size() or float(value) != floor(float(value))):
			return "enum parameter '%s' requires a numeric option index in [0, %d)" % [parameter_name, options.size()]
	return ""


func _action_validate_graph_fragment(args : Dictionary) -> Dictionary:
	var graph_edit = _get_graph_edit(args, false)
	var errors : Array[String] = []
	var warnings : Array[String] = []
	var nodes = args.get("nodes", null)
	var connections = args.get("connections", [])
	if graph_edit == null:
		errors.append("no material project open")
	if not nodes is Array or nodes.is_empty():
		errors.append("'nodes' must be a non-empty array")
		return { valid = false, errors = errors, warnings = warnings, node_count = 0, connection_count = 0 }
	if nodes.size() > MAX_BATCH_NODES:
		errors.append("too many nodes (maximum %d)" % MAX_BATCH_NODES)
	if not connections is Array:
		errors.append("'connections' must be an array")
		connections = []

	var temporary : Dictionary = {}
	for index in range(nodes.size()):
		var node_data = nodes[index]
		if not node_data is Dictionary:
			errors.append("node %d must be an object" % index)
			continue
		var type_name : String = str(node_data.get("type", ""))
		if type_name == "":
			errors.append("node %d is missing 'type'" % index)
			continue
		var alias : String = str(node_data.get("name", type_name))
		if alias == "":
			errors.append("node %d has an empty name" % index)
			continue
		if temporary.has(alias):
			errors.append("duplicate fragment node name '%s'; give repeated node types explicit unique names" % alias)
			continue
		var generator = await mm_loader.create_gen(node_data.duplicate(true))
		if generator == null:
			errors.append("unknown or invalid node type '%s'" % type_name)
			continue
		temporary[alias] = generator
		if graph_edit != null and _get_generator(graph_edit, alias) != null:
			warnings.append("node name '%s' already exists and Material Maker will rename the new node" % alias)
		var parameters = node_data.get("parameters", {})
		if not parameters is Dictionary:
			errors.append("parameters for '%s' must be an object" % alias)
		else:
			for parameter_name in parameters.keys():
				var parameter_error := _parameter_validation_error(generator, str(parameter_name), parameters[parameter_name])
				if parameter_error != "":
					errors.append("node '%s': %s" % [alias, parameter_error])

	var adjacency : Dictionary = {}
	if graph_edit != null and graph_edit.generator != null:
		for existing_connection in graph_edit.generator.connections:
			var existing_from : String = str(existing_connection.from)
			if not adjacency.has(existing_from):
				adjacency[existing_from] = []
			adjacency[existing_from].append(str(existing_connection.to))
	for index in range(connections.size()):
		var connection = connections[index]
		if not connection is Dictionary:
			errors.append("connection %d must be an object" % index)
			continue
		var missing : Array[String] = []
		for key in [ "from", "from_port", "to", "to_port" ]:
			if not connection.has(key):
				missing.append(key)
		if not missing.is_empty():
			errors.append("connection %d is missing %s" % [index, ", ".join(missing)])
			continue
		var from_name : String = str(connection.from)
		var to_name : String = str(connection.to)
		var from_gen = temporary.get(from_name, _get_generator(graph_edit, from_name))
		var to_gen = temporary.get(to_name, _get_generator(graph_edit, to_name))
		if from_gen == null:
			errors.append("connection %d references unknown source node '%s'" % [index, from_name])
		if to_gen == null:
			errors.append("connection %d references unknown target node '%s'" % [index, to_name])
		if from_gen != null:
			var from_error := _validate_port(from_gen, int(connection.from_port), true)
			if from_error != "":
				errors.append("connection %d source '%s': %s" % [index, from_name, from_error])
		if to_gen != null:
			var to_error := _validate_port(to_gen, int(connection.to_port), false)
			if to_error != "":
				errors.append("connection %d target '%s': %s" % [index, to_name, to_error])
		if not adjacency.has(from_name):
			adjacency[from_name] = []
		adjacency[from_name].append(to_name)
	if _graph_has_cycle(adjacency):
		errors.append("connections would create a graph cycle")

	for generator in temporary.values():
		if generator != null and is_instance_valid(generator):
			generator.free()
	return {
		valid = errors.is_empty(),
		errors = errors,
		warnings = warnings,
		node_count = nodes.size(),
		connection_count = connections.size(),
	}


func _action_remove_node(args : Dictionary):
	var graph_edit = _get_graph_edit(args)
	if graph_edit == null:
		return _error("no material project open")
	var node_name : String = str(args.get("node", ""))
	var ui_node = graph_edit.get_node_or_null("node_"+node_name)
	if ui_node == null:
		return _error("unknown node '%s'" % node_name)
	graph_edit.remove_node(ui_node)
	return { removed = node_name }


func _action_move_node(args : Dictionary):
	var graph_edit = _get_graph_edit(args)
	var node_name : String = str(args.get("node", ""))
	var gen = _get_generator(graph_edit, node_name)
	var ui_node = _get_ui_node(graph_edit, node_name)
	if gen == null or ui_node == null:
		return _error("unknown node '%s'" % node_name)
	if not args.get("position", null) is Array or args.position.size() != 2:
		return _error("'position' must be [x, y]")
	var new_position := _vector2_arg(args, "position", gen.position)
	graph_edit.undoredo_move_node(gen.name, gen.position, new_position)
	ui_node.do_set_position(new_position)
	gen.set_position(new_position)
	graph_edit.send_changed_signal()
	return _node_details(gen)


func _action_duplicate_node(args : Dictionary):
	var graph_edit = _get_graph_edit(args)
	var node_name : String = str(args.get("node", ""))
	var gen = _get_generator(graph_edit, node_name)
	if gen == null:
		return _error("unknown node '%s'" % node_name)
	var data : Dictionary = gen.serialize().duplicate(true)
	data.erase("name")
	var default_position : Vector2 = gen.position + Vector2(80, 80)
	var position := _vector2_arg(args, "position", default_position)
	data.node_position = { x = 0, y = 0 }
	var nodes : Array = await graph_edit.create_nodes(data, position)
	if nodes.is_empty():
		return _error("failed to duplicate node '%s'" % node_name)
	return _node_details(nodes[0].generator)


func _action_connect_nodes(args : Dictionary):
	var graph_edit = _get_graph_edit(args)
	if graph_edit == null:
		return _error("no material project open")
	for k in [ "from", "from_port", "to", "to_port" ]:
		if not args.has(k):
			return _error("missing '%s'" % k)
	var from_gen = _get_generator(graph_edit, str(args.from))
	var to_gen = _get_generator(graph_edit, str(args.to))
	var from_ui : String = "node_"+str(args.from)
	var to_ui : String = "node_"+str(args.to)
	if from_gen == null or to_gen == null or graph_edit.get_node_or_null(from_ui) == null or graph_edit.get_node_or_null(to_ui) == null:
		return _error("unknown node '%s' or '%s'" % [str(args.from), str(args.to)])
	var port_error := _validate_port(from_gen, int(args.from_port), true)
	if port_error != "":
		return _error("node '%s': %s" % [str(args.from), port_error])
	port_error = _validate_port(to_gen, int(args.to_port), false)
	if port_error != "":
		return _error("node '%s': %s" % [str(args.to), port_error])
	if graph_edit.do_connect_node(from_ui, int(args.from_port), to_ui, int(args.to_port)):
		return { connected = true }
	return _error("connection failed (check port indexes/types)")


func _action_disconnect_nodes(args : Dictionary):
	var graph_edit = _get_graph_edit(args)
	if graph_edit == null:
		return _error("no material project open")
	for k in [ "from", "from_port", "to", "to_port" ]:
		if not args.has(k):
			return _error("missing '%s'" % k)
	var from_gen = _get_generator(graph_edit, str(args.from))
	var to_gen = _get_generator(graph_edit, str(args.to))
	var from_ui : String = "node_"+str(args.from)
	var to_ui : String = "node_"+str(args.to)
	if from_gen == null or to_gen == null or graph_edit.get_node_or_null(from_ui) == null or graph_edit.get_node_or_null(to_ui) == null:
		return _error("unknown node '%s' or '%s'" % [str(args.from), str(args.to)])
	var port_error := _validate_port(from_gen, int(args.from_port), true)
	if port_error != "":
		return _error("node '%s': %s" % [str(args.from), port_error])
	port_error = _validate_port(to_gen, int(args.to_port), false)
	if port_error != "":
		return _error("node '%s': %s" % [str(args.to), port_error])
	if graph_edit.do_disconnect_node(from_ui, int(args.from_port), to_ui, int(args.to_port)):
		return { disconnected = true }
	return _error("no such connection")


func _action_set_parameter(args : Dictionary):
	var graph_edit = _get_graph_edit(args)
	var gen = _get_generator(graph_edit, str(args.get("node", "")))
	if gen == null:
		return _error("unknown node '%s'" % str(args.get("node", "")))
	var parameter_name : String = str(args.get("name", ""))
	if parameter_name == "" or not args.has("value"):
		return _error("missing 'name' or 'value'")
	var parameter_error := _parameter_validation_error(gen, parameter_name, args.value)
	if parameter_error != "":
		return _error(parameter_error, "invalid_parameter")
	gen.set_parameter(parameter_name, MMType.deserialize_value(args.value))
	return { node = gen.name, name = parameter_name, value = MMType.serialize_value(gen.get_parameter(parameter_name)) }


func _action_get_parameter(args : Dictionary):
	var graph_edit = _get_graph_edit(args, false)
	var gen = _get_generator(graph_edit, str(args.get("node", "")))
	if gen == null:
		return _error("unknown node '%s'" % str(args.get("node", "")))
	var parameter_name : String = str(args.get("name", ""))
	if parameter_name == "":
		return _error("missing 'name'")
	if gen.get_parameter_def(parameter_name).is_empty() and not gen.parameters.has(parameter_name):
		return _error("unknown parameter '%s' on node '%s'" % [parameter_name, gen.name])
	return { node = gen.name, name = parameter_name, value = MMType.serialize_value(gen.get_parameter(parameter_name)) }


func _action_render_node(args : Dictionary):
	var graph_edit = _get_graph_edit(args)
	var gen = _get_generator(graph_edit, str(args.get("node", "")))
	if gen == null:
		return _error("unknown node '%s'" % str(args.get("node", "")))
	var size := Vector2i(512, 512)
	if args.has("size") and args.size is Array and args.size.size() == 2:
		size = Vector2i(int(args.size[0]), int(args.size[1]))
	var output : int = int(args.get("output", 0))
	var port_error := _validate_port(gen, output, true)
	if port_error != "":
		return _error("node '%s': %s" % [gen.name, port_error])
	if size.x < 1 or size.y < 1 or size.x > 8192 or size.y > 8192:
		return _error("render size must be between 1 and 8192 pixels per dimension")
	var path : String = str(args.get("path", ""))
	if path == "":
		return _error("missing 'path'")
	var image : Image = await gen.render_output(output, size)
	if image == null:
		return _error("render failed")
	var err : Error = image.save_png(path)
	if err != OK:
		return _error("cannot save image to '%s' (error %d)" % [path, err])
	return { path = path, size = [size.x, size.y] }


func _preview_model_index(preview, model_name : String) -> int:
	if model_name == "" or model_name == "current":
		return preview.objects.get_children().find(preview.current_object)
	var normalized : String = model_name.to_lower()
	for index in range(preview.objects.get_child_count()):
		if preview.objects.get_child(index).name.to_lower() == normalized:
			return index
	return -1


func _update_specific_material_preview(material_node, preview) -> void:
	var materials : Dictionary[Node, Array] = {}
	var preview_materials : Array = preview.get_materials()
	materials[preview] = preview_materials
	await material_node.set_3d_previews(materials)
	# MMGenMaterial.set_3d_previews() starts update_material() without awaiting it.
	# Await explicitly so capture/restoration cannot race texture or shader assignment.
	for preview_material in preview_materials:
		await material_node.update_material(preview_material, true)


func _graph_dependency_buffers_busy(graph_edit) -> bool:
	var root = graph_edit.generator
	for buffer in mm_deps.buffers.values():
		var object = buffer.object
		if object == null or not is_instance_valid(object) or not object is Node:
			continue
		if object == root or root.is_ancestor_of(object):
			if buffer.status != 3 and buffer.status != 4: # Buffer.Updated / Buffer.Error
				return true
	return false


func _wait_for_material_settle(graph_edit, material_node, timeout_msec : int = 8000) -> bool:
	var buffer = mm_deps.buffers.get(material_node.buffer_name_prefix)
	if buffer == null:
		return false
	var previous_generation : int = buffer.shader_generations
	# MMGenMaterial.update() itself launches shader compilation asynchronously.
	# Trigger one known generation and wait for that exact target buffer to finish.
	material_node.update()
	var started : int = Time.get_ticks_msec()
	var idle_frames : int = 0
	while Time.get_ticks_msec() - started < timeout_msec:
		await get_tree().process_frame
		buffer = mm_deps.buffers.get(material_node.buffer_name_prefix)
		if (
				buffer != null
				and buffer.shader_generations > previous_generation
				and not material_node.update_scheduled
				and not _graph_dependency_buffers_busy(graph_edit)):
			idle_frames += 1
			if idle_frames >= 3:
				return true
		else:
			idle_frames = 0
	return false


func _action_render_material_preview(args : Dictionary):
	var previous_material_id : String = _material_id_for(_get_graph_edit({}, false))
	var result = await _render_material_preview_impl(args)
	if previous_material_id != "":
		_get_graph_edit({ material_id = previous_material_id })
	return result


func _render_material_preview_impl(args : Dictionary):
	var previous_graph_edit = _get_graph_edit({}, false)
	var previous_material_id : String = _material_id_for(previous_graph_edit)
	var previous_material_node = previous_graph_edit.get_material_node() if previous_graph_edit != null else null
	var graph_edit = _get_graph_edit(args)
	var material_node = graph_edit.get_material_node() if graph_edit != null else null
	if graph_edit == null or material_node == null:
		return _error("no material with a PBR output is open", "material_not_found")
	var path : String = str(args.get("path", ""))
	if path == "" or path.get_extension().to_lower() != "png":
		return _error("preview path must end in .png", "invalid_path")
	var size := Vector2i(512, 512)
	if args.has("size") and args.size is Array and args.size.size() == 2:
		size = Vector2i(int(args.size[0]), int(args.size[1]))
	if size.x < 64 or size.y < 64 or size.x > 2048 or size.y > 2048:
		return _error("preview size must be between 64 and 2048 pixels per dimension", "invalid_size")
	var preview = mm_globals.main_window.get_panel("Preview3D")
	if preview == null or not preview.is_node_ready():
		return _error("3D preview panel is not ready", "preview_not_ready", ["Wait for Material Maker to finish initializing and retry"])
	if not await _wait_for_material_settle(graph_edit, material_node):
		if previous_material_id != "" and previous_material_id != _material_id_for(graph_edit):
			_get_graph_edit({ material_id = previous_material_id })
		return _error(
				"material did not finish updating before the preview timeout",
				"preview_update_timeout",
				["Reduce graph complexity or retry after Material Maker finishes rendering"])
	var model_name : String = str(args.get("model", "sphere"))
	var model_index := _preview_model_index(preview, model_name)
	if model_index < 0:
		return _error(
				"unknown preview model '%s'" % model_name,
				"invalid_preview_model",
				["Use current, cube, cylinder, sphere, plane, or prism"])

	var viewport : SubViewport = preview.get_node("MaterialPreview")
	var animator : AnimationPlayer = preview.get_node("MaterialPreview/Preview3d/ObjectRotate")
	var original_model_index : int = preview.objects.get_children().find(preview.current_object)
	var original_transform : Transform3D = preview.objects_pivot.transform
	var original_size : Vector2i = viewport.size
	var viewport_container = viewport.get_parent()
	var original_stretch : bool = viewport_container.stretch if viewport_container is SubViewportContainer else false
	var original_update_mode : int = viewport.render_target_update_mode
	var animation_was_playing : bool = animator.is_playing()
	animator.pause()
	if model_index != original_model_index:
		preview.select_object(model_index)
	if args.has("rotation") and args.rotation is Array and args.rotation.size() == 3:
		preview.objects_pivot.rotation_degrees = Vector3(
				float(args.rotation[0]), float(args.rotation[1]), float(args.rotation[2]))
	else:
		preview.objects_pivot.rotation_degrees = Vector3(-15.0, 30.0, 0.0)
	if viewport_container is SubViewportContainer:
		viewport_container.stretch = false
	viewport.size = size
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	await _update_specific_material_preview(material_node, preview)
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image : Image = viewport.get_texture().get_image()
	var error : Error = ERR_CANT_CREATE
	if image != null and not image.is_empty():
		if image.get_width() != size.x or image.get_height() != size.y:
			image.resize(size.x, size.y, Image.INTERPOLATE_LANCZOS)
		error = image.save_png(path)

	viewport.size = original_size
	if viewport_container is SubViewportContainer:
		viewport_container.stretch = original_stretch
	viewport.render_target_update_mode = original_update_mode
	preview.objects_pivot.transform = original_transform
	if original_model_index >= 0 and original_model_index != model_index:
		preview.select_object(original_model_index)
	if animation_was_playing:
		animator.play()
	if previous_material_id != "" and previous_material_id != _material_id_for(graph_edit):
		_get_graph_edit({ material_id = previous_material_id })
	if previous_material_node != null and is_instance_valid(previous_material_node):
		await _update_specific_material_preview(previous_material_node, preview)
	else:
		await _update_specific_material_preview(material_node, preview)

	if image == null or image.is_empty():
		return _error("3D preview returned an empty image", "preview_failed")
	if error != OK:
		return _error("cannot save preview to '%s' (error %d)" % [path, error], "write_failed")
	return {
		path = path,
		size = [image.get_width(), image.get_height()],
		model = preview.objects.get_child(model_index).name,
		material_id = _material_id_for(graph_edit),
	}


func _action_export_material(args : Dictionary):
	var graph_edit = _get_graph_edit(args)
	if graph_edit == null:
		return _error("no material project open")
	var material_node : MMGenMaterial = graph_edit.get_material_node()
	if material_node == null:
		return _error("no material node in current project")
	var prefix : String = str(args.get("prefix", ""))
	var profile : String = str(args.get("profile", ""))
	if prefix == "" or profile == "":
		return _error("missing 'prefix' or 'profile'")
	var profiles : Array = material_node.get_export_profiles()
	if profiles.find(profile) == -1:
		return _error(
				"unknown profile '%s' (available: %s)" % [profile, ", ".join(profiles)],
				"unknown_export_profile",
				["Call list_export_profiles and use one of the returned names"])
	var output_dir : String = prefix.get_base_dir()
	if not DirAccess.dir_exists_absolute(output_dir):
		return _error(
				"export directory does not exist: '%s'" % output_dir,
				"invalid_export_directory",
				["Create the destination directory before exporting"])
	var before : Dictionary = _export_file_snapshot(prefix)
	await material_node.export_material(prefix, profile, int(args.get("size", 0)))
	var files : Array[Dictionary] = _export_file_manifest(prefix, before)
	if files.is_empty():
		return _error(
				"export completed but produced no files for prefix '%s'" % prefix,
				"empty_export",
				["Verify that the material output is connected", "Try a non-zero export size"])
	return {
		exported = prefix,
		profile = profile,
		material_id = _material_id_for(graph_edit),
		file_count = files.size(),
		files = files,
	}


func _export_file_snapshot(prefix : String) -> Dictionary:
	var snapshot : Dictionary = {}
	var output_dir : String = prefix.get_base_dir()
	var prefix_name : String = prefix.get_file()
	for file_name in DirAccess.get_files_at(output_dir):
		if not file_name.begins_with(prefix_name):
			continue
		var path : String = output_dir.path_join(file_name)
		var file : FileAccess = FileAccess.open(path, FileAccess.READ)
		if file == null:
			continue
		snapshot[path] = {
			size_bytes = file.get_length(),
			modified_unix = FileAccess.get_modified_time(path),
			sha256 = FileAccess.get_sha256(path),
		}
	return snapshot


func _export_file_manifest(prefix : String, before : Dictionary) -> Array[Dictionary]:
	var manifest : Array[Dictionary] = []
	var output_dir : String = prefix.get_base_dir()
	var prefix_name : String = prefix.get_file()
	var after : Dictionary = _export_file_snapshot(prefix)
	for path in after:
		var file_name : String = str(path).get_file()
		var suffix : String = file_name.trim_prefix(prefix_name).trim_prefix("_")
		var fingerprint : Dictionary = after[path]
		manifest.append({
			path = path,
			filename = file_name,
			channel = suffix.get_basename() if suffix != "" else file_name.get_basename(),
			extension = file_name.get_extension().to_lower(),
			size_bytes = fingerprint.size_bytes,
			modified_unix = fingerprint.modified_unix,
			sha256 = fingerprint.sha256,
			changed = not before.has(path) or before[path] != fingerprint,
		})
	manifest.sort_custom(func(a : Dictionary, b : Dictionary): return a.filename < b.filename)
	return manifest


func _variation_combinations(dimensions : Array[Dictionary]) -> Array:
	var combinations : Array = [[]]
	for dimension in dimensions:
		var expanded : Array = []
		for combination in combinations:
			for value in dimension.values:
				var next_combination : Array = combination.duplicate(true)
				next_combination.append({
					node = dimension.node,
					parameter = dimension.parameter,
					value = value,
					generator = dimension.generator,
				})
				expanded.append(next_combination)
		combinations = expanded
	return combinations


func _restore_variation_state(
		dimensions : Array[Dictionary], graph_edit, original_dirty : bool,
		previous_material_id : String) -> void:
	for dimension in dimensions:
		if is_instance_valid(dimension.generator):
			dimension.generator.set_parameter(dimension.parameter, dimension.original)
	await get_tree().process_frame
	graph_edit.need_save = original_dirty
	if previous_material_id != "" and previous_material_id != _material_id_for(graph_edit):
		_get_graph_edit({ material_id = previous_material_id })


func _action_render_variations(args : Dictionary):
	var output_dir : String = str(args.get("output_dir", ""))
	if output_dir == "" or not DirAccess.dir_exists_absolute(output_dir):
		return _error(
				"variation output directory does not exist: '%s'" % output_dir,
				"invalid_output_directory",
				["Create the output directory before rendering variations"])
	var mode : String = str(args.get("mode", "preview")).to_lower()
	if mode != "preview" and mode != "export":
		return _error("variation mode must be 'preview' or 'export'", "invalid_variation_mode")
	var size : int = int(args.get("size", 256))
	if size < 64 or size > 2048:
		return _error("variation size must be between 64 and 2048", "invalid_size")
	var variations = args.get("variations", null)
	if not variations is Dictionary or variations.is_empty():
		return _error("'variations' must be a non-empty object", "invalid_variations")

	var previous_graph_edit = _get_graph_edit({}, false)
	var previous_material_id : String = _material_id_for(previous_graph_edit)
	var graph_edit = _get_graph_edit(args, false)
	if graph_edit == null or graph_edit.get_material_node() == null:
		return _error("no material with a PBR output is open", "material_not_found")
	var material_id : String = _material_id_for(graph_edit)
	var profile : String = str(args.get("profile", ""))
	if mode == "export":
		var profiles : Array = graph_edit.get_material_node().get_export_profiles()
		if profile == "" or profiles.find(profile) == -1:
			return _error(
					"export mode requires a valid profile (available: %s)" % ", ".join(profiles),
					"unknown_export_profile")

	var dimensions : Array[Dictionary] = []
	var combination_count : int = 1
	for node_name_value in variations:
		var node_name : String = str(node_name_value)
		var generator = _get_generator(graph_edit, node_name)
		if generator == null:
			return _error("unknown variation node '%s'" % node_name, "unknown_node")
		var parameters = variations[node_name_value]
		if not parameters is Dictionary or parameters.is_empty():
			return _error("variations for node '%s' must be a non-empty object" % node_name, "invalid_variations")
		for parameter_value in parameters:
			var parameter : String = str(parameter_value)
			if generator.get_parameter_def(parameter).is_empty() and not generator.parameters.has(parameter):
				return _error(
						"unknown parameter '%s' on node '%s'" % [parameter, node_name],
						"unknown_parameter")
			var values = parameters[parameter_value]
			if not values is Array or values.is_empty():
				return _error(
						"variation '%s.%s' must contain at least one value" % [node_name, parameter],
						"invalid_variations")
			combination_count *= values.size()
			for value in values:
				var parameter_error := _parameter_validation_error(generator, parameter, value)
				if parameter_error != "":
					return _error(parameter_error, "invalid_parameter")
			if combination_count > MAX_VARIATION_COMBINATIONS:
				return _error(
						"variation sweep creates %d combinations (maximum %d)" % [combination_count, MAX_VARIATION_COMBINATIONS],
						"too_many_variations",
						["Use fewer values or split the sweep into multiple calls"])
			dimensions.append({
				node = node_name,
				parameter = parameter,
				values = values.duplicate(true),
				original = generator.get_parameter(parameter),
				generator = generator,
			})

	var original_dirty : bool = graph_edit.need_save
	var results : Array[Dictionary] = []
	var failure : Dictionary = {}
	var combinations : Array = _variation_combinations(dimensions)
	for index in range(combinations.size()):
		var combination : Array = combinations[index]
		var values : Dictionary = {}
		for change in combination:
			change.generator.set_parameter(change.parameter, MMType.deserialize_value(change.value))
			values["%s.%s" % [change.node, change.parameter]] = _json_value(
					change.generator.get_parameter(change.parameter))
		await get_tree().process_frame
		var basename : String = "variation_%03d" % (index + 1)
		var rendered
		if mode == "preview":
			rendered = await _action_render_material_preview({
				path = output_dir.path_join(basename + ".png"),
				size = [size, size],
				model = str(args.get("model", "sphere")),
				rotation = args.get("rotation", [-15.0, 30.0, 0.0]),
				material_id = material_id,
			})
		else:
			rendered = await _action_export_material({
				prefix = output_dir.path_join(basename),
				profile = profile,
				size = size,
				material_id = material_id,
			})
		if rendered is Dictionary and rendered.has("__error"):
			failure = rendered
			failure.details = failure.get("__details", {}).merged({ variation_index = index + 1, values = values })
			break
		results.append({ index = index + 1, values = values, output = rendered })

	await _restore_variation_state(dimensions, graph_edit, original_dirty, previous_material_id)
	if not failure.is_empty():
		return _error(
				"variation %d failed: %s" % [failure.details.variation_index, failure.__error],
				str(failure.get("__code", "variation_render_failed")),
				failure.get("__possible_solutions", []),
				{ completed = results, failed = failure.details, state_restored = true })
	return {
		material_id = material_id,
		mode = mode,
		profile = profile if mode == "export" else "",
		combination_count = combinations.size(),
		results = results,
		state_restored = true,
		original_dirty_restored = graph_edit.need_save == original_dirty,
	}


func _action_list_export_profiles(args : Dictionary):
	var graph_edit = _get_graph_edit(args, false)
	if graph_edit == null:
		return _error("no material project open")
	var material_node : MMGenMaterial = graph_edit.get_material_node()
	if material_node == null:
		return _error("no material node in current project")
	return { profiles = material_node.get_export_profiles() }


func _undo_state(graph_edit) -> Dictionary:
	return {
		material_id = _material_id_for(graph_edit),
		can_undo = graph_edit.undoredo.can_undo(),
		can_redo = graph_edit.undoredo.can_redo(),
		dirty = graph_edit.need_save,
	}


func _action_undo(args : Dictionary):
	var graph_edit = _get_graph_edit(args)
	if graph_edit == null:
		return _error("unknown or missing material", "material_not_found", ["Call list_materials and pass a valid material_id"])
	if not graph_edit.undoredo.can_undo():
		return _error("nothing to undo", "nothing_to_undo")
	graph_edit.undoredo.undo()
	await get_tree().process_frame
	return _undo_state(graph_edit)


func _action_redo(args : Dictionary):
	var graph_edit = _get_graph_edit(args)
	if graph_edit == null:
		return _error("unknown or missing material", "material_not_found", ["Call list_materials and pass a valid material_id"])
	if not graph_edit.undoredo.can_redo():
		return _error("nothing to redo", "nothing_to_redo")
	graph_edit.undoredo.redo()
	await get_tree().process_frame
	return _undo_state(graph_edit)


# --- Documentation interface ---------------------------------------------------

func _action_list_actions(_args : Dictionary) -> Array:
	var rv : Array = []
	for action_name in actions.keys():
		var a : Dictionary = actions[action_name]
		rv.append({
			name = action_name,
			description = a.description,
			args = a.args,
			implemented = a.handler != _action_not_implemented,
		})
	return rv


func _action_describe(args : Dictionary):
	var topic : String = str(args.get("topic", ""))
	match topic:
		"actions":
			return _action_list_actions(args)
		"action":
			var action_name : String = str(args.get("name", ""))
			if not actions.has(action_name):
				return _error("unknown action '%s'" % action_name)
			var a : Dictionary = actions[action_name]
			return { name = action_name, description = a.description, args = a.args,
					implemented = a.handler != _action_not_implemented }
		"node_types":
			return _action_list_node_types(args)
		"node_type":
			return _action_describe_node_type(args)
		_:
			return _error("unknown topic '%s' (use actions|action|node_types|node_type)" % topic)


func _action_list_node_types(args : Dictionary):
	var file : FileAccess = FileAccess.open(LIBRARY_PATH, FileAccess.READ)
	if file == null:
		return _error("cannot read library %s" % LIBRARY_PATH)
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK or not json.data is Dictionary:
		return _error("cannot parse library %s" % LIBRARY_PATH)
	var category_filter : String = str(args.get("category", "")).to_lower()
	var rv : Array = []
	for item in json.data.get("lib", []):
		if not item is Dictionary or not item.has("type"):
			continue
		var category : String = str(item.get("tree_item", ""))
		if category_filter != "" and not category.to_lower().begins_with(category_filter):
			continue
		# Deliberately compact (no icon_data / parameters) to keep responses small.
		rv.append({
			type = item.type,
			label = item.get("display_name", item.get("name", "")),
			category = category,
		})
	return rv


func _action_describe_node_type(args : Dictionary):
	var type_name : String = str(args.get("name", ""))
	if not mm_loader.predefined_generators.has(type_name):
		return _error("unknown node type '%s'" % type_name)
	var definition : Dictionary = mm_loader.predefined_generators[type_name]
	var rv : Dictionary = { type = type_name }
	var shader_model : Dictionary = definition.get("shader_model", {})
	for k in [ "name", "shortdesc", "longdesc" ]:
		if shader_model.has(k):
			rv[k] = shader_model[k]
	rv.parameters = _doc_entries(shader_model.get("parameters", []))
	rv.inputs = _doc_entries(shader_model.get("inputs", []))
	rv.outputs = _doc_entries(shader_model.get("outputs", []))
	return rv


# Extracts only the documentation-relevant keys from parameter/input/output
# definitions (drops GLSL code, widgets and other bulky fields).
func _doc_entries(entries : Array) -> Array:
	const KEEP : Array = [ "name", "label", "type", "default", "min", "max", "step", "values", "shortdesc" ]
	var rv : Array = []
	for e in entries:
		if not e is Dictionary:
			continue
		var d : Dictionary = {}
		for k in KEEP:
			if e.has(k):
				d[k] = e[k]
		rv.append(d)
	return rv


# --- TCP server ---------------------------------------------------------------

func start_server(port : int) -> bool:
	if server != null:
		return false
	server = TCPServer.new()
	var err : Error = server.listen(port, HOST)
	if err != OK:
		push_warning("mcp_bridge: cannot listen on %s:%d (error %d)" % [HOST, port, err])
		server = null
		_update_menu_status()
		return false
	current_port = port
	print("mcp_bridge: listening on %s:%d" % [HOST, port])
	_update_menu_status()
	return true


func stop_server() -> void:
	for client in clients:
		client.peer.disconnect_from_host()
	clients.clear()
	pending_requests.clear()
	if server != null:
		server.stop()
		server = null
	_update_menu_status()


func is_running() -> bool:
	return server != null and server.is_listening()


func _process(_delta : float) -> void:
	# Once per second: re-add our global menu if the app rebuilt its menus
	# (which clears it), and inject our tab into a newly opened Preferences
	# dialog.
	menu_guard_elapsed += _delta
	if menu_guard_elapsed >= 1.0:
		menu_guard_elapsed = 0.0
		if using_global_menu:
			_ensure_global_menu()
		_check_preferences_dialog()
	if server == null:
		return
	while server.is_connection_available():
		var peer : StreamPeerTCP = server.take_connection()
		if peer != null:
			clients.append({ peer = peer, buffer = PackedByteArray() })
	for i in range(clients.size() - 1, -1, -1):
		var client : Dictionary = clients[i]
		var peer : StreamPeerTCP = client.peer
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			clients.remove_at(i)
			continue
		var available : int = peer.get_available_bytes()
		if available <= 0:
			continue
		var data : Array = peer.get_partial_data(available)
		if data[0] != OK:
			continue
		client.buffer.append_array(data[1])
		if client.buffer.size() > MAX_REQUEST_BYTES:
			_send(client, { ok = false, error = "request exceeds maximum size" })
			peer.disconnect_from_host()
			clients.remove_at(i)
			continue
		var pos : int = client.buffer.find(10)
		while pos != -1:
			var line : String = client.buffer.slice(0, pos).get_string_from_utf8()
			client.buffer = client.buffer.slice(pos + 1)
			if not line.strip_edges().is_empty():
				_handle_line(client, line)
			pos = client.buffer.find(10)


func _handle_line(client : Dictionary, line : String) -> void:
	var response : Dictionary = {}
	var json := JSON.new()
	if json.parse(line) != OK or not json.data is Dictionary:
		response.ok = false
		response.error = "invalid JSON request"
		_send(client, response)
		return
	var request : Dictionary = json.data
	if request.has("id"):
		response.id = request.id
	var action_name : String = str(request.get("action", ""))
	var args = request.get("args", {})
	if not args is Dictionary:
		args = {}
	if not actions.has(action_name):
		response.ok = false
		response.error = "unknown action '%s'" % action_name
		response.code = "unknown_action"
		response.possible_solutions = ["Call list_actions to inspect the registered bridge actions"]
		_send(client, response)
	else:
		pending_requests.append({ client = client, response = response, action = action_name, args = args })
		if not request_active:
			_drain_request_queue()


func _drain_request_queue() -> void:
	if request_active:
		return
	request_active = true
	while not pending_requests.is_empty():
		var request : Dictionary = pending_requests.pop_front()
		active_action = request.action
		active_action_started_msec = Time.get_ticks_msec()
		var result = await actions[active_action].handler.call(request.args)
		var response : Dictionary = request.response
		if result is Dictionary and result.has("__error"):
			response.ok = false
			response.error = result.__error
			response.code = result.get("__code", "bridge_error")
			if not result.get("__possible_solutions", []).is_empty():
				response.possible_solutions = result.__possible_solutions
			if not result.get("__details", {}).is_empty():
				response.details = result.__details
			_record_error(active_action, request.args, response)
		else:
			response.ok = true
			response.result = result
		response.duration_msec = Time.get_ticks_msec() - active_action_started_msec
		_send(request.client, response)
	active_action = ""
	active_action_started_msec = 0
	request_active = false


func _record_error(action_name : String, args : Dictionary, response : Dictionary) -> void:
	recent_errors.append({
		timestamp_msec = Time.get_ticks_msec(),
		action = action_name,
		code = response.get("code", "bridge_error"),
		error = response.get("error", "unknown error"),
		argument_keys = args.keys(),
	})
	while recent_errors.size() > MAX_RECENT_ERRORS:
		recent_errors.pop_front()


func _send(client : Dictionary, response : Dictionary) -> void:
	var peer : StreamPeerTCP = client.peer
	if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		peer.put_data((JSON.stringify(response) + "\n").to_utf8_buffer())


func _error(
		message : String,
		code : String = "bridge_error",
		possible_solutions : Array = [],
		details : Dictionary = {}) -> Dictionary:
	return {
		__error = message,
		__code = code,
		__possible_solutions = possible_solutions,
		__details = details,
	}


# --- Menu injection -----------------------------------------------------------
# Adds an "MCP" menu at runtime, without touching main_window.tscn/.gd.
# On macOS the app menus live in the DisplayServer global menu bar, so the
# in-app MenuButton would be invisible there; use the global menu instead.

func _inject_menu() -> void:
	while mm_globals.main_window == null:
		await get_tree().process_frame
	if DisplayServer.has_feature(DisplayServer.FEATURE_GLOBAL_MENU):
		using_global_menu = true
		_rebuild_global_menu()
	else:
		var menu_container : Control = mm_globals.main_window.get_node_or_null("VBoxContainer/TopBar/Menu")
		if menu_container == null:
			return
		menu_button = MenuButton.new()
		menu_button.text = "MCP"
		menu_button.flat = false
		var popup : PopupMenu = menu_button.get_popup()
		popup.add_check_item("Server enabled", 0)
		popup.add_item("Settings...", 1)
		popup.add_separator()
		popup.add_item("", 100)
		popup.set_item_disabled(popup.get_item_index(100), true)
		status_item_id = 100
		popup.id_pressed.connect(_on_menu_id_pressed)
		menu_container.add_child(menu_button)
	print("mcp_bridge: menu injected (global_menu=%s)" % str(using_global_menu))
	_update_menu_status()


# --- macOS global menu (DisplayServer) -----------------------------------------

func _rebuild_global_menu() -> void:
	DisplayServer.global_menu_clear(GLOBAL_MENU)
	DisplayServer.global_menu_add_submenu_item("_main", "MCP", GLOBAL_MENU)
	var cb : Callable = _on_global_menu_item
	global_enabled_index = DisplayServer.global_menu_add_check_item(GLOBAL_MENU, "Server enabled", cb, cb, "enabled")
	DisplayServer.global_menu_add_item(GLOBAL_MENU, "Settings...", cb, cb, "settings")
	DisplayServer.global_menu_add_separator(GLOBAL_MENU)
	global_status_index = DisplayServer.global_menu_add_item(GLOBAL_MENU, "", Callable(), Callable(), "status")
	DisplayServer.global_menu_set_item_disabled(GLOBAL_MENU, global_status_index, true)
	global_menu_main_count = DisplayServer.global_menu_get_item_count("_main")


func _ensure_global_menu() -> void:
	# main_window.do_update_menus() clears "_main" whenever the app rebuilds
	# its menus; if our submenu vanished with it, add it back.
	var count : int = DisplayServer.global_menu_get_item_count("_main")
	if count < global_menu_main_count:
		_rebuild_global_menu()
		_update_menu_status()


func _on_global_menu_item(tag) -> void:
	match str(tag):
		"enabled":
			_toggle_server()
		"settings":
			_open_preferences()
	_update_menu_status()


# --- Shared menu logic -----------------------------------------------------------

func _on_menu_id_pressed(id : int) -> void:
	match id:
		0:
			_toggle_server()
		1:
			_open_preferences()
	_update_menu_status()


func _toggle_server() -> void:
	if is_running():
		stop_server()
	else:
		start_server(get_port())


func _update_menu_status() -> void:
	var status_text : String = "Server stopped"
	if is_running():
		status_text = "Server running on %s:%d" % [HOST, current_port]
	if using_global_menu:
		if global_status_index != -1:
			DisplayServer.global_menu_set_item_text(GLOBAL_MENU, global_status_index, status_text)
		if global_enabled_index != -1:
			DisplayServer.global_menu_set_item_checked(GLOBAL_MENU, global_enabled_index, is_running())
	elif menu_button != null:
		var popup : PopupMenu = menu_button.get_popup()
		var idx : int = popup.get_item_index(status_item_id)
		if idx != -1:
			popup.set_item_text(idx, status_text)
		idx = popup.get_item_index(0)
		if idx != -1:
			popup.set_item_checked(idx, is_running())


# --- Preferences integration ------------------------------------------------------
# Injects an "MCP" tab into the app's Preferences dialog at runtime. The
# preferences mechanism (preferences.gd) calls init_from_config() /
# update_config() on every control in the dialog, so our option controls
# integrate with Apply/OK/Cancel without any core changes.

class MCPAutostartOption:
	extends HBoxContainer
	var checkbox : CheckBox
	func _init() -> void:
		var label : Label = Label.new()
		label.text = "Start MCP server automatically"
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		add_child(label)
		checkbox = CheckBox.new()
		add_child(checkbox)
	func init_from_config(c : ConfigFile) -> void:
		checkbox.button_pressed = c.get_value("config", "mcp_bridge_autostart", true)
	func update_config(c : ConfigFile) -> void:
		c.set_value("config", "mcp_bridge_autostart", checkbox.button_pressed)


class MCPPortOption:
	extends HBoxContainer
	var spinbox : SpinBox
	func _init() -> void:
		var label : Label = Label.new()
		label.text = "Port"
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		add_child(label)
		spinbox = SpinBox.new()
		spinbox.min_value = 1024
		spinbox.max_value = 65535
		add_child(spinbox)
	func init_from_config(c : ConfigFile) -> void:
		spinbox.value = c.get_value("config", "mcp_bridge_port", DEFAULT_PORT)
	func update_config(c : ConfigFile) -> void:
		c.set_value("config", "mcp_bridge_port", int(spinbox.value))


func _open_preferences() -> void:
	if mm_globals.main_window != null:
		mm_globals.main_window.edit_preferences()
		_check_preferences_dialog.call_deferred()


func _check_preferences_dialog() -> void:
	if mm_globals.main_window == null:
		return
	for w in mm_globals.main_window.get_children():
		if w is Window and w.has_method("edit_preferences") and not w.has_meta("mcp_bridge_injected"):
			_inject_preferences_tab(w)


func _inject_preferences_tab(dialog : Window) -> void:
	var tabs : TabContainer = dialog.get_node_or_null("HSplitContainer/PreferencesPanel/VBoxContainer/TabContainer")
	if tabs == null:
		return
	dialog.set_meta("mcp_bridge_injected", true)
	var scroll : ScrollContainer = ScrollContainer.new()
	scroll.name = "MCP"
	var vbox : VBoxContainer = VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vbox)
	var status : Label = Label.new()
	if is_running():
		status.text = "Status: server running on %s:%d" % [HOST, current_port]
	else:
		status.text = "Status: server stopped (toggle it in the MCP menu)"
	vbox.add_child(status)
	var version_label : Label = Label.new()
	version_label.text = "Bridge version: %s" % BRIDGE_VERSION
	vbox.add_child(version_label)
	vbox.add_child(HSeparator.new())
	vbox.add_child(MCPAutostartOption.new())
	vbox.add_child(MCPPortOption.new())
	var note : Label = Label.new()
	note.text = "The external MCP host (mcp_bridge_host) connects to this port.\nChanging the port restarts the server if it is running."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(note)
	tabs.add_child(scroll)
	# The Preferences dialog navigates via a category sidebar tree that is
	# built once from the TabContainer children (preferences_tree.gd), so
	# rebuild it to make our tab selectable.
	var tree : Tree = dialog.get_node_or_null("HSplitContainer/PreferenceCategory/Tree")
	if tree != null and tree.has_method("update_tree"):
		tree.update_tree()
	# Defer so the preferences dialog picks up our controls when it
	# initializes its own (edit_preferences() runs update_controls first).
	dialog.update_controls.call_deferred(scroll)
	if dialog.has_signal("config_changed"):
		dialog.config_changed.connect(_on_preferences_changed)


func _on_preferences_changed() -> void:
	var new_port : int = get_port()
	if is_running() and new_port != current_port:
		stop_server()
		start_server(new_port)
	_update_menu_status()
