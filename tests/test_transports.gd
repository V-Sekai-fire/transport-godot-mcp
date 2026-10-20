extends SceneTree
## Headless tests for the protocol versions, batches, the tool trim, tool providers, tools that
## take frames, the 2024-11-05 HTTP+SSE routes and the stdio line handler.
## Run: godot --headless --path . --script res://tests/test_transports.gd

const Protocol = preload("res://addons/vsekai_godot_mcp/mcp_protocol.gd")
const Http = preload("res://addons/vsekai_godot_mcp/mcp_http_server.gd")
const Stdio = preload("res://addons/vsekai_godot_mcp/mcp_stdio.gd")
const Pending = preload("res://addons/vsekai_godot_mcp/mcp_pending.gd")

var _fail := 0
var _pass := 0


class FakeTools:
	extends RefCounted
	var later = null
	func tool_defs() -> Array:
		return [
			{ "name": "echo", "description": "Echo.", "inputSchema": { "type": "object", "properties": { "x": {} } } },
			{ "name": "get_node", "description": "Hides the built-in.", "inputSchema": { "type": "object" } },
			{ "name": "picture", "description": "An image block.", "inputSchema": { "type": "object" } },
			{ "name": "slow", "description": "Finishes later.", "inputSchema": { "type": "object" } },
		]
	func call_tool(name: String, args: Dictionary):
		match name:
			"echo": return { "x": args.get("x") }
			"get_node": return { "mine": true }
			"picture": return { "__content__": [ { "type": "image", "data": "AAAA", "mimeType": "image/png" } ] }
			"slow":
				later = Pending.new()
				return later
		return { "__error__": true, "msg": "no" }


func _initialize() -> void:
	await _run()
	print("\n[godot_mcp transport tests] %d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		printerr("  FAIL: ", msg)


func _req(method: String, params = null, id = 1) -> Dictionary:
	var m := { "jsonrpc": "2.0", "method": method }
	if params != null:
		m["params"] = params
	if id != null:
		m["id"] = id
	return m


func _names(tools: Array) -> Array:
	return tools.map(func(t): return t.name)


func _run() -> void:
	var p = Protocol.new()

	# --- versions: echo a supported one, else answer with the newest ---
	for v in ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]:
		var ini = p.handle_rpc(_req("initialize", { "protocolVersion": v, "capabilities": {}, "clientInfo": { "name": "t", "version": "0" } }))
		_check(ini.result.protocolVersion == v, "initialize echoes " + v)
	_check(p.handle_rpc(_req("initialize", { "protocolVersion": "1999-01-01" })).result.protocolVersion == "2025-11-25", "unknown version -> newest")
	_check(p.handle_rpc(_req("initialize")).result.protocolVersion == "2025-11-25", "no params -> newest")

	# --- batches ---
	var b = p.handle_rpc([_req("ping", null, 1), _req("notifications/initialized", null, null), _req("tools/list", null, 2)])
	_check(b is Array and b.size() == 2, "batch answers each request, not the notification")
	_check(b is Array and b.size() == 2 and b[0].id == 1 and b[1].id == 2, "batch keeps the order and ids")
	_check(p.handle_rpc([_req("notifications/initialized", null, null)]) == null, "batch of notifications -> no reply")
	var empty = p.handle_rpc([])
	_check(empty is Dictionary and empty.has("error") and empty.error.code == -32600, "empty batch -> -32600")

	# --- ids: Godot reads JSON numbers as floats; a whole-number id must go back as one ---
	var echoed := JSON.stringify(p.handle_rpc(JSON.parse_string("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"ping\"}")))
	_check("\"id\":7," in echoed or "\"id\":7}" in echoed, "id 7 goes back as 7, not 7.0: " + echoed)
	_check(JSON.stringify(p.handle_rpc(_req("ping", null, "abc"))).contains("\"id\":\"abc\""), "string id unchanged")

	# --- trim: allow keeps only the named built-ins ---
	var t = Protocol.new()
	t.allow = PackedStringArray(["ping", "get_scene_tree"])
	var listed = _names(t.handle_rpc(_req("tools/list")).result.tools)
	_check(listed.size() == 2 and "ping" in listed and "get_scene_tree" in listed, "allow trims tools/list")
	var gone = t.handle_rpc(_req("tools/call", { "name": "set_property", "arguments": {} }))
	_check(gone.has("error") and gone.error.code == -32602, "a trimmed tool cannot be called")

	# --- annotations ---
	var all_tools: Array = p.handle_rpc(_req("tools/list")).result.tools
	var gn = all_tools.filter(func(x): return x.name == "get_node")[0]
	var sp = all_tools.filter(func(x): return x.name == "set_property")[0]
	_check(gn.get("annotations", {}).get("readOnlyHint", false) == true, "get_node is marked read-only")
	_check(not sp.has("annotations"), "set_property is not marked read-only")

	# --- providers ---
	var f := FakeTools.new()
	t.providers.append(f)
	listed = _names(t.handle_rpc(_req("tools/list")).result.tools)
	_check("echo" in listed and "get_node" in listed and "ping" in listed, "provider tools join the trimmed list")
	_check(listed.count("get_node") == 1, "one get_node in the list")
	var e = t.handle_rpc(_req("tools/call", { "name": "echo", "arguments": { "x": 5 } }))
	_check(e.result.isError == false and e.result.structuredContent.x == 5, "dictionary result -> structuredContent")
	_check(JSON.parse_string(e.result.content[0].text).x == 5, "and the same as text")
	var hidden = t.handle_rpc(_req("tools/call", { "name": "get_node", "arguments": {} }))
	_check(hidden.result.structuredContent.get("mine", false), "a provider tool hides the built-in")
	var pic = t.handle_rpc(_req("tools/call", { "name": "picture", "arguments": {} }))
	_check(pic.result.content[0].type == "image" and not pic.result.has("structuredContent"), "__content__ passes through")

	# --- a tool that takes frames ---
	var pend = t.handle_rpc(_req("tools/call", { "name": "slow", "arguments": {} }, 77))
	_check(pend is Pending and not pend.finished, "slow tool -> MCPPending")
	(func(): f.later.finish({ "late": 1 })).call_deferred()
	var settled = await Pending.settle(pend)
	_check(settled is Dictionary and settled.id == 77 and settled.result.structuredContent.late == 1, "pending settles to the full response")
	var pb = t.handle_rpc([_req("ping", null, 1), _req("tools/call", { "name": "slow", "arguments": {} }, 2)])
	(func(): f.later.finish("ok")).call_deferred()
	var sb = await Pending.settle(pb)
	_check(sb.size() == 2 and sb[1].id == 2 and sb[1].result.content[0].text == "\"ok\"", "batch with a pending item settles")

	# --- HTTP: version headers and both transports ---
	var h = Http.new()
	h.protocol = t
	for v in ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]:
		_check(h.route("POST", "/mcp", { "mcp-protocol-version": v }, JSON.stringify(_req("ping"))).code == 200, "header " + v + " accepted")
	var batch_http = h.route("POST", "/mcp", {}, JSON.stringify([_req("ping", null, 1), _req("ping", null, 2)]))
	_check(batch_http.code == 200 and JSON.parse_string(batch_http.body).size() == 2, "HTTP batch")
	_check(h.route("GET", "/sse", {}, "").get("open_stream", false), "GET /sse opens a stream")
	_check(h.route("POST", "/sse", {}, "").code == 405, "POST /sse -> 405")
	_check(h.route("POST", "/messages?session_id=nope", {}, JSON.stringify(_req("ping"))).code == 404, "unknown session -> 404")
	var sid: String = h.open_session(null)
	var m = h.route("POST", "/messages?session_id=" + sid, {}, JSON.stringify(_req("ping", null, 9)))
	_check(m.code == 202 and m.deliver_to == sid and m.payload.id == 9, "POST /messages -> 202, answer goes to the stream")
	var m2 = h.route("POST", "/messages?sessionId=" + sid, {}, JSON.stringify(_req("ping", null, 10)))
	_check(m2.code == 202 and m2.payload.id == 10, "sessionId spelling accepted")
	var bad = h.route("POST", "/messages?session_id=" + sid, {}, "{not json")
	_check(bad.code == 202 and bad.payload.error.code == -32700, "bad JSON on /messages -> -32700 on the stream")
	var slow = h.route("POST", "/mcp", {}, JSON.stringify(_req("tools/call", { "name": "slow", "arguments": {} }, 5)))
	_check(slow.has("pending"), "slow tool over HTTP -> pending")
	(func(): f.later.finish(1)).call_deferred()
	var done = await Pending.settle(slow.pending)
	_check(h.format_response(done, false).code == 200 and JSON.parse_string(h.format_response(done, false).body).id == 5, "pending formats as a 200 answer")
	_check(Http.query_param("/messages?a=1&session_id=x%20y", "session_id") == "x y", "query_param decodes")
	_check(Http.sse_event("endpoint", "/m") == "event: endpoint\ndata: /m\n\n", "SSE framing")

	# --- 2026-07-28 (modern): per-request _meta, server/discover, header mirroring ---
	var meta := { "io.modelcontextprotocol/protocolVersion": "2026-07-28",
		"io.modelcontextprotocol/clientCapabilities": {},
		"io.modelcontextprotocol/clientInfo": { "name": "t", "version": "0" } }
	var disc = t.handle_rpc(_req("server/discover", { "_meta": meta }))
	_check(disc.result.supportedVersions == ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"], "server/discover lists every version")
	_check(disc.result.resultType == "complete" and disc.result.has("ttlMs") and disc.result.cacheScope == "public", "discover is a cacheable modern result")
	_check(disc.result._meta["io.modelcontextprotocol/serverInfo"].name == "vsekai-godot-mcp", "discover names the server in _meta")
	var ml = t.handle_rpc(_req("tools/list", { "_meta": meta }))
	_check(ml.result.resultType == "complete" and ml.result.ttlMs > 0 and ml.result.tools.size() == listed.size(), "modern tools/list")
	var legacy_list = t.handle_rpc(_req("tools/list"))
	_check(not legacy_list.result.has("resultType") and not legacy_list.result.has("ttlMs"), "legacy tools/list has no modern fields")
	var mc = t.handle_rpc(_req("tools/call", { "name": "echo", "arguments": { "x": 2 }, "_meta": meta }))
	_check(mc.result.resultType == "complete" and mc.result.structuredContent.x == 2 and mc.result._meta.has("io.modelcontextprotocol/serverInfo"), "modern tools/call")
	var mslow = t.handle_rpc(_req("tools/call", { "name": "slow", "arguments": {}, "_meta": meta }, 31))
	(func(): f.later.finish(3)).call_deferred()
	var mdone = await Pending.settle(mslow)
	_check(mdone.id == 31 and mdone.result.resultType == "complete", "modern slow tool gets resultType too")
	_check(t.handle_rpc(_req("ping", { "_meta": meta })).error.code == -32601, "modern ping is gone")
	var future := meta.duplicate()
	future["io.modelcontextprotocol/protocolVersion"] = "2099-01-01"
	var uv = t.handle_rpc(_req("tools/list", { "_meta": future }))
	_check(uv.error.code == -32022 and uv.error.data.requested == "2099-01-01" and "2026-07-28" in uv.error.data.supported, "unsupported version -> -32022 with the list")
	_check(t.handle_rpc(_req("initialize", { "protocolVersion": "2026-07-28" })).result.protocolVersion == "2025-11-25", "initialize never picks a modern version")

	var good := { "mcp-protocol-version": "2026-07-28", "mcp-method": "tools/call", "mcp-name": "echo" }
	var call_body := JSON.stringify(_req("tools/call", { "name": "echo", "arguments": { "x": 1 }, "_meta": meta }))
	_check(h.route("POST", "/mcp", good, call_body).code == 200, "modern call with matching headers -> 200")
	var wrong_method := good.duplicate(); wrong_method["mcp-method"] = "tools/list"
	var hm = h.route("POST", "/mcp", wrong_method, call_body)
	_check(hm.code == 400 and JSON.parse_string(hm.body).error.code == -32020, "Mcp-Method mismatch -> 400 -32020")
	var no_name := good.duplicate(); no_name.erase("mcp-name")
	_check(h.route("POST", "/mcp", no_name, call_body).code == 400, "missing Mcp-Name -> 400")
	var b64 := good.duplicate(); b64["mcp-name"] = "=?base64?" + Marshalls.utf8_to_base64("echo") + "?="
	_check(h.route("POST", "/mcp", b64, call_body).code == 200, "Base64 Mcp-Name decodes")
	var old_header := good.duplicate(); old_header["mcp-protocol-version"] = "2025-11-25"
	_check(h.route("POST", "/mcp", old_header, call_body).code == 400, "header version must match _meta")
	var fut_body := JSON.stringify(_req("tools/list", { "_meta": future }))
	var fut = h.route("POST", "/mcp", { "mcp-protocol-version": "2099-01-01", "mcp-method": "tools/list" }, fut_body)
	_check(fut.code == 400 and JSON.parse_string(fut.body).error.code == -32022, "unsupported version over HTTP -> 400 -32022")
	var nf = h.route("POST", "/mcp", { "mcp-protocol-version": "2026-07-28", "mcp-method": "nope/x" }, JSON.stringify(_req("nope/x", { "_meta": meta })))
	_check(nf.code == 404 and JSON.parse_string(nf.body).error.code == -32601, "modern unknown method -> 404 -32601")
	var legacy_nf = h.route("POST", "/mcp", {}, JSON.stringify(_req("nope/x")))
	_check(legacy_nf.code == 200, "legacy unknown method stays 200")

	# --- stdio line handler ---
	var s = Stdio.new()
	s.protocol = t
	var out := []
	s.sink = func(text): out.append(JSON.parse_string(text))
	s.handle_line(JSON.stringify(_req("ping", null, 3)))
	s.handle_line(JSON.stringify(_req("notifications/initialized", null, null)))
	s.handle_line("not json")
	s.handle_line("   ")
	s.handle_line(JSON.stringify(_req("tools/call", { "name": "slow", "arguments": {} }, 4)))
	await process_frame
	_check(out.size() == 2, "stdio: two answers before the slow one (ping, parse error)")
	f.later.finish("x")
	await process_frame
	_check(out.size() == 3 and out[2].id == 4, "stdio: the slow answer follows")
	_check(out.size() >= 2 and out[0].id == 3 and out[1].error.code == -32700, "stdio: ping, then -32700")
