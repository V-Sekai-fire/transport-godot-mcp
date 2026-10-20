extends SceneTree
## Runs the runtime MCP server for tests/interop.py, trimmed the way a game trims it.
## godot --headless --quiet --path . --script res://tests/serve.gd -- [--mcp-port=N] [--mcp-stdio]


func _initialize() -> void:
	ProjectSettings.set_setting("vsekai_godot_mcp/allow", PackedStringArray(["ping", "get_scene_tree", "get_node"]))
	ProjectSettings.set_setting("vsekai_godot_mcp/providers", PackedStringArray(["res://tests/slow_tools.gd"]))
	ProjectSettings.set_setting("vsekai_godot_mcp/server_name", "interop-test")
	ProjectSettings.set_setting("vsekai_godot_mcp/listen_by_default", false)
	var scene := Node3D.new()
	scene.name = "Interop"
	root.add_child(scene)
	current_scene = scene
	root.add_child(load("res://addons/vsekai_godot_mcp/mcp_runtime.gd").new())
