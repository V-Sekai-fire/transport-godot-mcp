extends SceneTree
## Tests for the A2A 1.0 endpoint (a2a.gd), driven through MCPHttpServer.route() with no sockets.
## Run: godot --path . --script res://tests/test_a2a.gd
const Http = preload("res://addons/vsekai_godot_mcp/mcp_http_server.gd")
const Pending = preload("res://addons/vsekai_godot_mcp/mcp_pending.gd")
const V := {"a2a-version": "1.0"}
var _fail := 0
var _pass := 0


func _initialize() -> void:
	await _run()
	print("\n[godot_mcp a2a tests] %d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		printerr("  FAIL: ", msg)


func _body(method: String, params, id = 7) -> String:
	return JSON.stringify({"jsonrpc": "2.0", "id": id, "method": method, "params": params})


## POST / and return the parsed JSON-RPC answer, waiting for a tool that takes frames.
func _rpc(h, method: String, params, headers := V, id = 7) -> Dictionary:
	var r: Dictionary = h.route("POST", "/", headers, _body(method, params, id))
	if r.has("pending"):
		return await Pending.settle(r.pending)
	return JSON.parse_string(r.body)


func _msg(text_or_data, extra := {}) -> Dictionary:
	var part := {"text": text_or_data} if text_or_data is String else {"data": text_or_data}
	var m := {"messageId": "u1", "role": "ROLE_USER", "parts": [part]}
	m.merge(extra, true)
	return {"message": m}


func _run() -> void:
	var h = Http.new()
	var root := Node3D.new()
	root.name = "Root"
	h.protocol.commands.root = root
	var slow = load("res://tests/slow_tools.gd").new()
	root.add_child(slow)
	get_root().add_child(root)
	h.protocol.providers.append(slow)

	# --- card -------------------------------------------------------------
	var c := h.route("GET", "/.well-known/agent-card.json", {}, "")
	var card = JSON.parse_string(c.body)
	_check(c.code == 200 and c.ctype == "application/json", "card -> 200 json")
	_check(card.supportedInterfaces[0].protocolBinding == "JSONRPC", "card: JSONRPC interface")
	_check(card.supportedInterfaces[0].protocolVersion == "1.0", "card: protocol 1.0")
	_check(card.capabilities.streaming == false and card.capabilities.pushNotifications == false, "card: no streaming, no push")
	var skill_ids := []
	for s in card.skills:
		skill_ids.append(s.id)
	_check("get_scene_tree" in skill_ids and "wait_frames" in skill_ids, "card: one skill per tool, providers included")
	for k in ["name", "description", "version", "defaultInputModes", "defaultOutputModes", "skills"]:
		_check(card.has(k), "card has " + k)
	_check(h.route("POST", "/.well-known/agent-card.json", {}, "").code == 405, "card POST -> 405")
	_check(h.route("GET", "/", {}, "").code == 405, "GET / -> 405")
	_check(h.route("POST", "/mcp", {}, _body("ping", {})).code == 200, "MCP still answers on /mcp")

	# --- protocol errors --------------------------------------------------
	_check((await _rpc(h, "ListTasks", {}, {})).error.code == -32009, "no A2A-Version -> -32009")
	_check((await _rpc(h, "ListTasks", {}, {"a2a-version": "0.3"})).error.code == -32009, "0.3 -> -32009")
	_check((await _rpc(h, "ListTasks", {}, {"a2a-version": "1.4"})).has("result"), "1.x accepted")
	_check((await _rpc(h, "Nope", {})).error.code == -32601, "unknown method -> -32601")
	_check((await _rpc(h, "ListTasks", [])).error.code == -32602, "params not an object -> -32602")
	_check(JSON.parse_string(h.route("POST", "/", V, "{bad").body).error.code == -32700, "bad JSON -> -32700")
	_check(JSON.parse_string(h.route("POST", "/", V, "[]").body).error.code == -32600, "not an object -> -32600")
	_check(JSON.parse_string(h.route("POST", "/", V, "x".repeat(300000)).body).error.code == -32600, "oversized body -> -32600")
	_check((await _rpc(h, "SendStreamingMessage", _msg("tools"))).error.code == -32004, "streaming -> -32004")
	_check((await _rpc(h, "SubscribeToTask", {"id": "x"})).error.code == -32004, "subscribe -> -32004")
	_check((await _rpc(h, "CreateTaskPushNotificationConfig", {})).error.code == -32003, "push config -> -32003")
	_check((await _rpc(h, "GetExtendedAgentCard", {})).error.code == -32004, "extended card -> -32004")
	# JSON.parse_string reads every number as a float, so look at the bytes on the wire.
	var raw: Dictionary = h.route("POST", "/", V, _body("ListTasks", {}, 7))
	_check('"id":7,' in raw.body and not ('"id":7.0' in raw.body), "request id echoed as an integer")
	_check((await _rpc(h, "ListTasks", {}, V, "abc")).id == "abc", "string id echoed")

	# --- SendMessage: text commands --------------------------------------
	var t = (await _rpc(h, "SendMessage", _msg("tools"))).result.task
	_check(t.status.state == "TASK_STATE_COMPLETED", "tools -> COMPLETED")
	_check(t.artifacts[0].parts[0].data.tools.size() >= 20, "tools lists the tools")
	_check(t.id != "" and t.contextId != "" and t.history[0].role == "ROLE_USER", "task has ids and history")

	var call = (await _rpc(h, "SendMessage", _msg("call get_scene_tree"))).result.task
	_check(call.status.state == "TASK_STATE_COMPLETED", "call get_scene_tree -> COMPLETED")
	_check(call.artifacts[0].parts[0].data.name == "Root", "artifact carries the tool result")

	# --- SendMessage: data part ------------------------------------------
	var d = (await _rpc(h, "SendMessage", _msg({"tool": "get_node", "arguments": {"path": "."}}))).result.task
	_check(d.status.state == "TASK_STATE_COMPLETED", "data part runs a tool")
	var bad = (await _rpc(h, "SendMessage", _msg({"tool": "get_node", "arguments": {"path": "Nope/Missing"}}))).result.task
	_check(bad.status.state == "TASK_STATE_FAILED", "tool error -> FAILED")
	_check(bad.status.message.role == "ROLE_AGENT" and bad.status.message.parts[0].text != "", "FAILED carries the error text")
	var unk = (await _rpc(h, "SendMessage", _msg("call no_such_tool"))).result.task
	_check(unk.status.state == "TASK_STATE_REJECTED", "unknown tool -> REJECTED")
	var plain = (await _rpc(h, "SendMessage", _msg("hello there"))).result.task
	_check(plain.status.state == "TASK_STATE_REJECTED" and "data part" in plain.status.message.parts[0].text, "plain text -> REJECTED with a hint")
	var badargs = (await _rpc(h, "SendMessage", _msg("call get_node not-json"))).result.task
	_check(badargs.status.state == "TASK_STATE_REJECTED", "bad call arguments -> REJECTED")

	# --- SendMessage: input validation ------------------------------------
	_check((await _rpc(h, "SendMessage", {})).error.code == -32602, "no message -> -32602")
	_check((await _rpc(h, "SendMessage", _msg("tools", {"role": "ROLE_AGENT"}))).error.code == -32602, "agent role -> -32602")
	_check((await _rpc(h, "SendMessage", _msg("tools", {"parts": []}))).error.code == -32602, "no parts -> -32602")
	_check((await _rpc(h, "SendMessage", _msg("tools", {"contextId": "bad id!"}))).error.code == -32602, "bad contextId -> -32602")
	_check((await _rpc(h, "SendMessage", _msg("tools", {"taskId": "unknown"}))).error.code == -32001, "unknown taskId -> -32001")
	_check((await _rpc(h, "SendMessage", _msg("tools", {"taskId": t.id}))).error.code == -32004, "message to a finished task -> -32004")
	var kept = (await _rpc(h, "SendMessage", _msg("tools", {"contextId": "ctx-1"}))).result.task
	_check(kept.contextId == "ctx-1", "contextId kept")

	# --- a tool that takes frames ----------------------------------------
	var r: Dictionary = h.route("POST", "/", V, _body("SendMessage", _msg({"tool": "wait_frames", "arguments": {"frames": 2}})))
	_check(r.has("pending") and r.sse == false, "slow tool -> pending")
	var later = await Pending.settle(r.pending)
	_check(later.result.task.status.state == "TASK_STATE_COMPLETED", "slow tool finishes COMPLETED")

	# --- GetTask / ListTasks / CancelTask --------------------------------
	var g = (await _rpc(h, "GetTask", {"id": t.id})).result
	_check(g.id == t.id and g.history.size() == 1, "GetTask returns the task")
	_check((await _rpc(h, "GetTask", {"id": t.id, "historyLength": 0})).result.history.size() == 0, "historyLength 0 drops history")
	_check((await _rpc(h, "GetTask", {"id": "nope"})).error.code == -32001, "GetTask unknown -> -32001")
	_check((await _rpc(h, "GetTask", {"id": t.id, "historyLength": -1})).error.code == -32602, "negative historyLength -> -32602")
	_check((await _rpc(h, "GetTask", {"id": t.id, "historyLength": 1.5})).error.code == -32602, "fractional historyLength -> -32602")
	_check((await _rpc(h, "GetTask", {})).error.code == -32602, "GetTask without id -> -32602")
	_check((await _rpc(h, "CancelTask", {"id": t.id})).error.code == -32002, "CancelTask on a finished task -> -32002")
	_check((await _rpc(h, "CancelTask", {"id": "nope"})).error.code == -32001, "CancelTask unknown -> -32001")

	var all = (await _rpc(h, "ListTasks", {})).result
	_check(all.totalSize >= 8 and all.pageSize == 50 and all.nextPageToken == "", "ListTasks defaults")
	_check(all.tasks[0].id == later.result.task.id, "ListTasks is newest first")
	var failed = (await _rpc(h, "ListTasks", {"status": "TASK_STATE_FAILED"})).result
	_check(failed.totalSize == 1 and failed.tasks[0].id == bad.id, "ListTasks filters by status")
	_check((await _rpc(h, "ListTasks", {"contextId": "ctx-1"})).result.totalSize == 1, "ListTasks filters by contextId")
	var p1 = (await _rpc(h, "ListTasks", {"pageSize": 2})).result
	_check(p1.tasks.size() == 2 and p1.nextPageToken == "2", "page 1 of 2")
	var p2 = (await _rpc(h, "ListTasks", {"pageSize": 2, "pageToken": "2"})).result
	_check(p2.tasks.size() == 2 and p2.tasks[0].id != p1.tasks[0].id, "page 2 differs")
	_check((await _rpc(h, "ListTasks", {"pageSize": 0})).error.code == -32602, "pageSize 0 -> -32602")
	_check((await _rpc(h, "ListTasks", {"pageSize": 101})).error.code == -32602, "pageSize 101 -> -32602")
	_check((await _rpc(h, "ListTasks", {"pageToken": "-1"})).error.code == -32602, "negative pageToken -> -32602")
	_check((await _rpc(h, "ListTasks", {"pageToken": "abc"})).error.code == -32602, "non-numeric pageToken -> -32602")
	_check((await _rpc(h, "ListTasks", {"status": "RUNNING"})).error.code == -32602, "unknown status -> -32602")
	_check(p1.tasks[0].history.size() == 0, "ListTasks leaves history out by default")

	# --- the store is capped ---------------------------------------------
	for i in 300:
		await _rpc(h, "SendMessage", _msg("tools"))
	_check((await _rpc(h, "ListTasks", {})).result.totalSize == 256, "task store is capped at 256")
	_check((await _rpc(h, "GetTask", {"id": t.id})).error.code == -32001, "the oldest task was evicted")

	# --- the allow trim applies to A2A too -------------------------------
	h.protocol.allow = PackedStringArray(["ping"])
	var trimmed = (await _rpc(h, "SendMessage", _msg("call get_scene_tree"))).result.task
	_check(trimmed.status.state == "TASK_STATE_REJECTED", "a trimmed tool is not callable over A2A")
	var trimmed_card = JSON.parse_string(h.route("GET", "/.well-known/agent-card.json", {}, "").body)
	_check(trimmed_card.skills.size() == 2, "the card lists only the allowed tool and the provider's")
	h.protocol.allow = PackedStringArray()

	root.queue_free()
