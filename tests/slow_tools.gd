extends Node
## A tool provider for tests/interop.py: `wait_frames` answers after `frames` frames, so the
## transports' wait for a tool that takes frames runs over real sockets and pipes.

const PendingLib = preload("res://addons/vsekai_godot_mcp/mcp_pending.gd")


func tool_defs() -> Array:
	return [{
		"name": "wait_frames",
		"description": "Answer after the given number of frames.",
		"inputSchema": { "type": "object", "properties": { "frames": { "type": "integer" } }, "required": ["frames"] },
		"annotations": { "readOnlyHint": true },
	}]


func call_tool(_name: String, args: Dictionary):
	var p = PendingLib.new()
	_wait.call_deferred(p, int(args.get("frames", 1)), Engine.get_process_frames())
	return p


func _wait(p, frames: int, start: int) -> void:
	for i in frames:
		await get_tree().process_frame
	p.finish({ "frames": Engine.get_process_frames() - start })
