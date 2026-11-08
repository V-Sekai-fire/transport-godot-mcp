@tool
extends RefCounted
## A2A 1.0 (JSON-RPC binding) on the MCP listener, written from https://a2a-protocol.org/latest/specification/
##
## Godot has no model, so a message names a tool instead of asking for one. Two forms:
## - a `data` part {"tool": "<name>", "arguments": {...}}
## - a `text` part: `tools` lists the tools, `call <tool> [json object]` runs one.
## Either runs through MCPProtocol.handle_rpc("tools/call"), so the trim (`allow`) and the providers
## are the same as over MCP. The result is a Task: COMPLETED with the tool result as an artifact,
## FAILED when the tool reports an error, REJECTED when the message names no known tool.
## Every task is already finished when SendMessage answers, so GetTask and ListTasks read a
## store of the last MAX_TASKS tasks, CancelTask answers TaskNotCancelable, and streaming is off.
##
## A request that carries an Origin header is refused (403) on every A2A path, so a web page
## cannot drive editor tools. /mcp is unchanged (enforce_origin there is still off by default).
##
## route() is transport-free (parsed request -> response parts), like MCPHttpServer.route().
## A tool that takes frames gives { "pending": MCPPending, "sse": false }, which poll() finishes.

const MCPProtocolLib = preload("mcp_protocol.gd")
const PendingLib = preload("mcp_pending.gd")

const CARD_PATH := "/.well-known/agent-card.json"
const A2A_MAJOR := "1"
const MAX_BODY := 262144
const MAX_TASKS := 256
const MAX_PARTS := 16
const MAX_STORED_BYTES := 1 << 20
const TASK_STATES := [
	"TASK_STATE_SUBMITTED",
	"TASK_STATE_WORKING",
	"TASK_STATE_COMPLETED",
	"TASK_STATE_FAILED",
	"TASK_STATE_CANCELED",
	"TASK_STATE_INPUT_REQUIRED",
	"TASK_STATE_REJECTED",
	"TASK_STATE_AUTH_REQUIRED",
]
const PUSH_METHODS := [
	"CreateTaskPushNotificationConfig",
	"GetTaskPushNotificationConfig",
	"ListTaskPushNotificationConfigs",
	"DeleteTaskPushNotificationConfig",
]

## What the card advertises as the agent's address; MCPHttpServer.start() sets it.
var public_url := "http://127.0.0.1:8788/"

var _tasks := {}  # task id -> task, oldest first
var _crypto := Crypto.new()
var _id_re := RegEx.create_from_string("^[A-Za-z0-9._:-]{1,128}$")


static func owns(path: String) -> bool:
	var bare := path.split("?")[0]
	return bare == CARD_PATH or bare == "/"


func route(method: String, path: String, headers: Dictionary, body: String, protocol) -> Dictionary:
	# A browser page always sends Origin, and can POST text/plain to a loopback port with no
	# preflight. `call run_script ...` would then run in the editor, so refuse before parsing.
	# An empty or "null" Origin (sandboxed iframe, file://) counts too. SDK, httpx and curl clients
	# send none.
	if headers.has("origin"):
		return {"code": 403, "ctype": "text/plain", "body": "browser requests are refused"}
	if method == "OPTIONS":
		return {"code": 204, "ctype": "text/plain", "body": ""}
	var bare := path.split("?")[0]
	if bare == CARD_PATH:
		if method != "GET":
			return {"code": 405, "ctype": "text/plain", "body": "GET the agent card"}
		return _http(card(protocol))
	if method != "POST":
		return {"code": 405, "ctype": "text/plain", "body": "POST A2A JSON-RPC here"}
	if body.length() > MAX_BODY:
		return _http(_err(null, -32600, "request too large"))
	var json := JSON.new()
	if json.parse(body) != OK:
		return _http(_err(null, -32700, "invalid JSON payload"))
	var req = json.data
	if (
		typeof(req) != TYPE_DICTIONARY
		or req.get("jsonrpc", "") != "2.0"
		or typeof(req.get("method", null)) != TYPE_STRING
	):
		return _http(_err(null, -32600, "request payload validation error"))
	var id = _json_id(req.get("id", null))
	# A missing header means a 0.3 client (spec 3.6.1); this endpoint speaks 1.x only.
	var version := String(headers.get("a2a-version", "")).strip_edges()
	if version.split(".")[0] != A2A_MAJOR:
		return _http(_err(id, -32009, "unsupported A2A version; this agent supports 1.0"))
	var params = req.get("params", {})
	if params == null:
		params = {}
	if typeof(params) != TYPE_DICTIONARY:
		return _http(_err(id, -32602, "invalid parameters"))
	var name := String(req.method)
	if name == "SendMessage":
		return _send_message(id, params, protocol)
	if name == "GetTask":
		return _http(_get_task(id, params))
	if name == "ListTasks":
		return _http(_list_tasks(id, params))
	if name == "CancelTask":
		return _http(_cancel_task(id, params))
	if name == "SendStreamingMessage" or name == "SubscribeToTask":
		return _http(_err(id, -32004, "streaming is not supported"))
	if name in PUSH_METHODS:
		return _http(_err(id, -32003, "push notifications are not supported"))
	if name == "GetExtendedAgentCard":
		return _http(_err(id, -32004, "extended agent card is not supported"))
	return _http(_err(id, -32601, "method not found"))


func card(protocol) -> Dictionary:
	var skills := []
	for t in protocol.tool_schemas():
		skills.append(
			{
				"id": String(t.get("name", "")),
				"name": String(t.get("name", "")),
				"description": String(t.get("description", "")),
				"tags": ["godot", "mcp"],
			}
		)
	return {
		"name": protocol.server_name,
		"description":
		(
			"Godot as an A2A agent. Send a data part {\"tool\": name, \"arguments\": {...}}, or text: "
			+ "`tools`, or `call <tool> [json object]`. The tools are the ones MCP serves."
		),
		"version": protocol.server_version,
		"supportedInterfaces":
		[{"url": public_url, "protocolBinding": "JSONRPC", "protocolVersion": "1.0"}],
		"capabilities":
		{"streaming": false, "pushNotifications": false, "extendedAgentCard": false},
		"defaultInputModes": ["application/json", "text/plain"],
		"defaultOutputModes": ["application/json", "text/plain"],
		"skills": skills,
	}


# --- SendMessage -------------------------------------------------------------


func _send_message(id, params: Dictionary, protocol) -> Dictionary:
	var msg = params.get("message", null)
	if typeof(msg) != TYPE_DICTIONARY or msg.get("role", "") != "ROLE_USER":
		return _http(_err(id, -32602, "message with role ROLE_USER required"))
	var parts = msg.get("parts", null)
	if typeof(parts) != TYPE_ARRAY or parts.is_empty() or parts.size() > MAX_PARTS:
		return _http(_err(id, -32602, "message needs 1 to %d parts" % MAX_PARTS))
	var clean_parts := []
	for p in parts:
		if typeof(p) != TYPE_DICTIONARY:
			return _http(_err(id, -32602, "a part must be an object"))
		clean_parts.append(_clean_part(p))
	if msg.get("taskId", null) != null:
		if typeof(msg.taskId) != TYPE_STRING or not _tasks.has(msg.taskId):
			return _http(_err(id, -32001, "task not found"))
		return _http(_err(id, -32004, "task is in a terminal state"))
	var ctx = msg.get("contextId", null)
	if ctx == null:
		ctx = _uuid()
	elif not _safe_id(ctx):
		return _http(_err(id, -32602, "invalid contextId"))
	var message_id = msg.get("messageId", null)
	var user_msg := {
		"messageId": message_id if _safe_id(message_id) else _uuid(),
		"role": "ROLE_USER",
		"contextId": ctx,
		"parts": clean_parts,
	}
	var tid := _uuid()
	user_msg["taskId"] = tid
	var call := _parse_call(clean_parts)
	var kind := String(call.kind)
	if kind == "tools":
		var listed := []
		for t in protocol.tool_schemas():
			listed.append({"name": t.get("name", ""), "description": t.get("description", "")})
		var done := _task(tid, ctx, "TASK_STATE_COMPLETED", user_msg, null, [_artifact([{"data": {"tools": listed}}])])
		return _http(_result(id, {"task": _remember(done)}))
	if kind == "call":
		var names := []
		for t in protocol.tool_schemas():
			names.append(String(t.get("name", "")))
		if not (String(call.tool) in names):
			var why := "unknown tool: " + String(call.tool)
			return _http(_result(id, {"task": _remember(_task(tid, ctx, "TASK_STATE_REJECTED", user_msg, why))}))
		var rpc = protocol.handle_rpc(
			{
				"jsonrpc": "2.0",
				"id": 1,
				"method": "tools/call",
				"params": {"name": call.tool, "arguments": call.args},
			}
		)
		if rpc is PendingLib:
			var later = rpc.then(func(resp): return _result(id, {"task": _finish_call(tid, ctx, user_msg, resp)}))
			return {"pending": later, "sse": false}
		return _http(_result(id, {"task": _finish_call(tid, ctx, user_msg, rpc)}))
	var hint := (
		String(call.get("why", ""))
		+ " Send a data part {\"tool\": name, \"arguments\": {...}}, or text `tools` or `call <tool> [json]`."
	).strip_edges()
	return _http(_result(id, {"task": _remember(_task(tid, ctx, "TASK_STATE_REJECTED", user_msg, hint))}))


## {kind: "call", tool, args} | {kind: "tools"} | {kind: "none", why}
func _parse_call(parts: Array) -> Dictionary:
	for p in parts:
		if p.has("data"):
			var d = p.data
			if typeof(d) == TYPE_DICTIONARY and typeof(d.get("tool", null)) == TYPE_STRING:
				var args = d.get("arguments", {})
				if args == null:
					args = {}
				if typeof(args) != TYPE_DICTIONARY:
					return {"kind": "none", "why": "arguments must be an object."}
				return {"kind": "call", "tool": d.tool, "args": args}
		elif p.has("text") and typeof(p.text) == TYPE_STRING:
			var text := String(p.text).strip_edges()
			if text == "tools":
				return {"kind": "tools"}
			if text.begins_with("call "):
				var rest := text.substr(5).strip_edges()
				var sp := rest.find(" ")
				var tool_name := rest if sp < 0 else rest.substr(0, sp)
				var args := {}
				if sp >= 0:
					var j := JSON.new()
					if j.parse(rest.substr(sp + 1)) != OK or typeof(j.data) != TYPE_DICTIONARY:
						return {"kind": "none", "why": "call arguments must be a JSON object."}
					args = j.data
				return {"kind": "call", "tool": tool_name, "args": args}
	return {"kind": "none", "why": "No tool named."}


func _finish_call(tid: String, ctx: String, user_msg: Dictionary, resp) -> Dictionary:
	if typeof(resp) != TYPE_DICTIONARY or not resp.has("result"):
		return _remember(_task(tid, ctx, "TASK_STATE_FAILED", user_msg, "the tool call failed"))
	var res: Dictionary = resp.result
	if res.get("isError", false):
		return _remember(_task(tid, ctx, "TASK_STATE_FAILED", user_msg, _content_text(res)))
	var parts := []
	if typeof(res.get("structuredContent", null)) == TYPE_DICTIONARY:
		parts.append({"data": res.structuredContent, "mediaType": "application/json"})
	else:
		for item in res.get("content", []):
			if typeof(item) != TYPE_DICTIONARY:
				continue
			if item.get("type", "") == "text":
				parts.append({"text": String(item.get("text", ""))})
			elif item.get("type", "") == "image":
				parts.append({"raw": String(item.get("data", "")), "mediaType": String(item.get("mimeType", ""))})
			else:
				parts.append({"data": item})
	return _remember(_task(tid, ctx, "TASK_STATE_COMPLETED", user_msg, null, [_artifact(parts)]))


func _content_text(res: Dictionary) -> String:
	var out := []
	for item in res.get("content", []):
		if typeof(item) == TYPE_DICTIONARY and item.get("type", "") == "text":
			out.append(String(item.get("text", "")))
	return "\n".join(out) if not out.is_empty() else "the tool reported an error"


func _artifact(parts: Array) -> Dictionary:
	if parts.is_empty():
		parts = [{"text": ""}]
	return {"artifactId": _uuid(), "name": "result", "parts": parts}


func _task(tid: String, ctx: String, state: String, user_msg: Dictionary, why, artifacts := []) -> Dictionary:
	var status := {"state": state, "timestamp": _now()}
	if why != null:
		status["message"] = {
			"messageId": _uuid(),
			"role": "ROLE_AGENT",
			"contextId": ctx,
			"taskId": tid,
			"parts": [{"text": String(why)}],
		}
	return {
		"id": tid,
		"contextId": ctx,
		"status": status,
		"artifacts": artifacts,
		"history": [user_msg],
	}


## Keep the task for GetTask/ListTasks; a result over MAX_STORED_BYTES is answered but kept
## without its artifacts, so 256 tasks cannot hold gigabytes.
func _remember(task: Dictionary) -> Dictionary:
	var keep := task
	if JSON.stringify(task).length() > MAX_STORED_BYTES:
		keep = task.duplicate(true)
		keep["artifacts"] = []
		keep.status["message"] = {
			"messageId": _uuid(),
			"role": "ROLE_AGENT",
			"contextId": task.contextId,
			"taskId": task.id,
			"parts": [{"text": "The result was too large to keep; run the tool again."}],
		}
	_tasks[task.id] = keep
	while _tasks.size() > MAX_TASKS:
		_tasks.erase(_tasks.keys()[0])
	return task


# --- GetTask / ListTasks / CancelTask ----------------------------------------


func _get_task(id, params: Dictionary) -> Dictionary:
	if typeof(params.get("id", null)) != TYPE_STRING:
		return _err(id, -32602, "id required")
	var hl := _int_param(params, "historyLength", 0, 100)
	if not hl[0]:
		return _err(id, -32602, "historyLength must be an integer from 0 to 100")
	if not _tasks.has(params.id):
		return _err(id, -32001, "task not found")
	return _result(id, _trim(_tasks[params.id], hl[1]))


func _list_tasks(id, params: Dictionary) -> Dictionary:
	var status = params.get("status", null)
	if status != null and not (status in TASK_STATES):
		return _err(id, -32602, "unknown status")
	var ctx = params.get("contextId", null)
	if ctx != null and not _safe_id(ctx):
		return _err(id, -32602, "invalid contextId")
	var size := _int_param(params, "pageSize", 1, 100)
	var hl := _int_param(params, "historyLength", 0, 100)
	if not size[0] or not hl[0]:
		return _err(id, -32602, "pageSize is 1 to 100, historyLength 0 to 100")
	var page_size: int = 50 if size[1] == null else size[1]
	var token = params.get("pageToken", null)
	var offset := 0
	if token != null and String(token) != "":
		var t := String(token)
		if (
			typeof(token) != TYPE_STRING
			or t.length() > 9
			or not t.is_valid_int()
			or t.begins_with("-")
			or t.begins_with("+")
		):
			return _err(id, -32602, "invalid pageToken")
		offset = int(t)
	var matches := []
	var ids := _tasks.keys()
	ids.reverse()  # newest first
	for tid in ids:
		var task: Dictionary = _tasks[tid]
		if status != null and task.status.state != status:
			continue
		if ctx != null and task.contextId != ctx:
			continue
		matches.append(task)
	var page := []
	for task in matches.slice(offset, offset + page_size):
		page.append(_trim(task, 0 if hl[1] == null else hl[1]))
	var more := offset + page_size < matches.size()
	return _result(
		id,
		{
			"tasks": page,
			"nextPageToken": str(offset + page_size) if more else "",
			"pageSize": page_size,
			"totalSize": matches.size(),
		}
	)


func _cancel_task(id, params: Dictionary) -> Dictionary:
	if typeof(params.get("id", null)) != TYPE_STRING:
		return _err(id, -32602, "id required")
	if not _tasks.has(params.id):
		return _err(id, -32001, "task not found")
	return _err(id, -32002, "task is finished and cannot be canceled")


func _trim(task: Dictionary, history_length) -> Dictionary:
	var out := task.duplicate(true)
	if history_length != null:
		var h: Array = out.get("history", [])
		out["history"] = [] if history_length == 0 else h.slice(maxi(0, h.size() - history_length))
	return out


## [valid, value-or-null]: an absent key is valid and null; a whole number in lo..hi is valid.
func _int_param(params: Dictionary, key: String, lo: int, hi: int) -> Array:
	if not params.has(key) or params[key] == null:
		return [true, null]
	var v = params[key]
	if typeof(v) != TYPE_INT and typeof(v) != TYPE_FLOAT:
		return [false, null]
	if v != floorf(v) or v < lo or v > hi:
		return [false, null]
	return [true, int(v)]


# --- small helpers -----------------------------------------------------------


func _clean_part(p: Dictionary) -> Dictionary:
	var out := {}
	for k in ["text", "data", "url", "raw", "mediaType", "filename"]:
		if p.has(k):
			out[k] = p[k]
	return out


func _safe_id(v) -> bool:
	return typeof(v) == TYPE_STRING and _id_re.search(v) != null


func _json_id(v):
	var t := typeof(v)
	if t == TYPE_STRING or t == TYPE_INT or t == TYPE_FLOAT:
		return MCPProtocolLib.json_id(v)
	return null


func _uuid() -> String:
	var b := _crypto.generate_random_bytes(16)
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	var h := b.hex_encode()
	return (
		"%s-%s-%s-%s-%s"
		% [h.substr(0, 8), h.substr(8, 4), h.substr(12, 4), h.substr(16, 4), h.substr(20, 12)]
	)


func _now() -> String:
	return Time.get_datetime_string_from_system(true) + "Z"


func _result(id, value) -> Dictionary:
	return {"jsonrpc": "2.0", "id": id, "result": value}


func _err(id, code: int, message: String) -> Dictionary:
	return {"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}


func _http(body: Dictionary) -> Dictionary:
	return {"code": 200, "ctype": "application/json", "body": JSON.stringify(body)}
