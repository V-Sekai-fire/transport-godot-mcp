@tool
extends RefCounted
class_name MCPWeb
## MCP in a web export, where nothing can listen on a port. Two ways in, one protocol:
##
## - `window.godotMcp.request(message)` takes one JSON-RPC message (object or string) and
##   resolves to the answer (null for a notification). Any page script, extension relay or test
##   harness talks MCP through it.
## - WebMCP: when the page's `navigator.modelContext` exists, every tool is registered there
##   (provideContext, else registerTool), so a browser agent can call it. The first window that
##   the frame can reach (top, then parent, then itself) and that has the API gets them.
##
## The frame's window and each reachable same-origin parent also get `godotMcp`, so the page that
## holds this export in an iframe reaches it as `godotMcp` too.

const MCPProtocolLib = preload("mcp_protocol.gd")
const PendingLib = preload("mcp_pending.gd")

const SHIM := """
(function () {
	const m = window.godotMcp || {};
	m._pending = new Map(); m._next = 1;
	m.request = function (msg) {
		const text = typeof msg === 'string' ? msg : JSON.stringify(msg);
		return new Promise(function (resolve) {
			const id = m._next++; m._pending.set(id, resolve); m._toGodot(id, text);
		});
	};
	m._resolve = function (id, text) {
		const r = m._pending.get(id);
		if (r) { m._pending.delete(id); r(text === '' ? null : JSON.parse(text)); }
	};
	m.windows = function () {
		const out = [];
		for (const w of [window.top, window.parent, window]) {
			try { if (w && w.navigator && out.indexOf(w) < 0) out.push(w); } catch (e) {}
		}
		return out;
	};
	m.register = async function () {
		for (const w of m.windows()) { try { w.godotMcp = m; } catch (e) {} }
		const list = await m.request({ jsonrpc: '2.0', id: 'godot-mcp-list', method: 'tools/list' });
		const tools = list.result.tools.map(function (t) {
			const tool = { name: t.name, description: t.description, inputSchema: t.inputSchema,
				execute: async function (args) {
					const r = await m.request({ jsonrpc: '2.0', id: 'godot-mcp-call', method: 'tools/call',
						params: { name: t.name, arguments: args || {} } });
					if (r.error) throw new Error(r.error.message);
					return r.result;
				} };
			if (t.annotations) tool.annotations = t.annotations;
			return tool;
		});
		for (const w of m.windows()) {
			let mc = null;
			try { mc = w.navigator.modelContext; } catch (e) {}
			if (!mc) continue;
			if (typeof mc.provideContext === 'function') { mc.provideContext({ tools: tools }); return 'provideContext'; }
			if (typeof mc.registerTool === 'function') { for (const t of tools) mc.registerTool(t); return 'registerTool'; }
		}
		return 'none';
	};
	window.godotMcp = m;
})();
"""

var protocol = MCPProtocolLib.new()
var _on_message: JavaScriptObject   # kept: JavaScriptBridge frees a callback nobody holds
var _mcp: JavaScriptObject


func start() -> int:
	if not OS.has_feature("web"):
		return ERR_UNAVAILABLE
	JavaScriptBridge.eval(SHIM, true)
	_mcp = JavaScriptBridge.get_interface("godotMcp")
	_on_message = JavaScriptBridge.create_callback(_on_js_message)
	_mcp._toGodot = _on_message
	# Registering asks this server for its tool list, so it runs after start() returns.
	_mcp.register()
	return OK


func _on_js_message(args: Array) -> void:
	var id := int(args[0])
	var req = JSON.parse_string(String(args[1]))
	var resp = protocol.parse_error_response(-32700, "parse error") if req == null else protocol.handle_rpc(req)
	_answer_later.call_deferred(id, resp)


func _answer_later(id: int, resp) -> void:
	var done = await PendingLib.settle(resp)
	_mcp._resolve(id, "" if done == null else JSON.stringify(done))
