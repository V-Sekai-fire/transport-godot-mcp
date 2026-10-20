@tool
extends RefCounted
class_name MCPStdio
## The MCP stdio transport: newline-delimited JSON-RPC on standard input, answers on standard
## output, one message per line. An MCP client starts the program and talks to it this way.
##
## Standard output must carry only MCP messages, but Godot prints its banner and every print()
## there. So start() turns Engine.print_to_stdout off and _send() turns it on only around each
## message; errors still go to standard error. Start the program with --quiet (-q) too, or the
## engine banner comes first, before any script runs.
##
## A thread blocks on standard input and queues the lines; poll() (main thread) answers them.
## End of input (the client closed the pipe) sets `closed`; the host should then quit.
## Not on the web: a browser has no standard input.

const MCPProtocolLib = preload("mcp_protocol.gd")
const PendingLib = preload("mcp_pending.gd")
## The longest line read at once. A longer line arrives in pieces that do not parse.
const LINE_BYTES := 64 << 20

var protocol = MCPProtocolLib.new()
var closed := false
var _thread: Thread
var _mutex := Mutex.new()
var _lines: Array = []
var _eof := false
## Where answers go. Tests replace it to capture them.
var sink: Callable = _print_line


func start() -> int:
	if OS.has_feature("web"):
		return ERR_UNAVAILABLE
	Engine.print_to_stdout = false
	_thread = Thread.new()
	return _thread.start(_read_loop)


func stop() -> void:
	Engine.print_to_stdout = true
	# The reader is blocked in a read; it ends when the client closes standard input.


func _read_loop() -> void:
	while true:
		var line := OS.read_string_from_stdin(LINE_BYTES)
		_mutex.lock()
		if line == "":
			_eof = true
			_mutex.unlock()
			return
		_lines.append(line)
		_mutex.unlock()


## Answer the queued lines. Call it every frame from the main thread.
func poll() -> void:
	_mutex.lock()
	var batch := _lines
	_lines = []
	var eof := _eof
	_mutex.unlock()
	for line in batch:
		handle_line(line)
	if eof and not closed:
		closed = true


## One line in; the answer goes to `sink` now, or later when a tool takes frames.
func handle_line(line: String) -> void:
	if line.strip_edges() == "":
		return
	var req = JSON.parse_string(line)
	# Every answer goes out deferred, so answers that need no frames keep the order of the lines.
	var resp = (
		protocol.parse_error_response(-32700, "parse error")
		if req == null
		else protocol.handle_rpc(req)
	)
	if resp == null:
		return
	_answer_later.call_deferred(resp)


func _answer_later(resp) -> void:
	var done = await PendingLib.settle(resp)
	if done != null:
		_send(done)


func _send(msg) -> void:
	sink.call(JSON.stringify(msg))


func _print_line(text: String) -> void:
	Engine.print_to_stdout = true
	printraw(text + "\n")
	Engine.print_to_stdout = false
