"""Interop check: the official MCP Python SDK against the Godot runtime server, over every
transport (stdio, streamable HTTP, the 2024-11-05 HTTP+SSE pair) and every protocol version
(2024-11-05, 2025-03-26, 2025-06-18, 2025-11-25 by initialize; 2026-07-28 per request).

    pixi run interop          # GODOT=<path to godot> to pick the binary

Prints one line per check and exits 1 when any fails.
"""

import asyncio
import json
import os
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.client import Client
from mcp.client.sse import sse_client

ROOT = Path(__file__).resolve().parent.parent
GODOT = os.environ.get("GODOT") or shutil.which("godot") or "godot"
LEGACY = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
MODERN = "2026-07-28"
TOOLS = {"ping", "get_scene_tree", "get_node", "wait_frames"}

failures = []


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


def server_cmd(*extra):
    return [GODOT, "--headless", "--quiet", "--path", str(ROOT), "--script", "res://tests/serve.gd", "--", *extra]


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _body(raw, ctype):
    if not raw:
        return None
    text = raw.decode()
    if "text/event-stream" in (ctype or ""):
        text = "".join(line[5:].strip() for line in text.splitlines() if line.startswith("data:"))
    return json.loads(text)


def post(port, body, headers=None):
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/mcp",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "Accept": "application/json, text/event-stream", **(headers or {})},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, _body(r.read(), r.headers.get("Content-Type"))
    except urllib.error.HTTPError as e:
        return e.code, _body(e.read(), e.headers.get("Content-Type"))


def meta(version=MODERN):
    return {
        "io.modelcontextprotocol/protocolVersion": version,
        "io.modelcontextprotocol/clientCapabilities": {},
        "io.modelcontextprotocol/clientInfo": {"name": "interop", "version": "0"},
    }


async def exercise(session, label):
    """The same four checks over any connected session."""
    names = {t.name for t in (await session.list_tools()).tools}
    check(names == TOOLS, f"{label}: tools/list is the trimmed list {sorted(names)}")
    tree = await session.call_tool("get_scene_tree", {})
    check(not tree.is_error and json.loads(tree.content[0].text).get("name") == "Interop", f"{label}: get_scene_tree")
    slow = await session.call_tool("wait_frames", {"frames": 5})
    frames = (slow.structured_content or {}).get("frames", 0)
    check(not slow.is_error and frames >= 5, f"{label}: wait_frames answered after {frames} frames")
    try:
        gone = await session.call_tool("set_property", {"path": ".", "property": "name", "value": "x"})
        refused = gone.is_error
    except Exception as e:  # the SDK raises on the JSON-RPC error -32602 (unknown tool)
        refused = "unknown tool" in str(e)
    check(refused, f"{label}: a trimmed tool is refused")


async def sdk_client(target, mode, label, want_version):
    async with Client(target, mode=mode) as client:
        got = client.session.protocol_version
        check(got == want_version, f"{label}: negotiated {got}")
        await exercise(client, label)


async def sse(port):
    async with sse_client(f"http://127.0.0.1:{port}/sse") as (read, write):
        async with ClientSession(read, write) as session:
            init = await session.initialize()
            v = getattr(init, "protocol_version", None) or getattr(init, "protocolVersion", None)
            check(v in LEGACY, f"sse: initialize -> {v}")
            await exercise(session, "sse")


def raw_http(port):
    for v in LEGACY:
        code, body = post(port, {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                 "params": {"protocolVersion": v, "capabilities": {}, "clientInfo": {"name": "raw", "version": "0"}}})
        check(code == 200 and body["result"]["protocolVersion"] == v, f"http raw: initialize {v} echoed")
        code, body = post(port, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}, {"MCP-Protocol-Version": v})
        check(code == 200 and len(body["result"]["tools"]) == len(TOOLS), f"http raw: tools/list with header {v}")
    h = {"MCP-Protocol-Version": MODERN, "Mcp-Method": "server/discover"}
    code, body = post(port, {"jsonrpc": "2.0", "id": 3, "method": "server/discover", "params": {"_meta": meta()}}, h)
    check(code == 200 and MODERN in body["result"]["supportedVersions"] and body["result"]["resultType"] == "complete",
          "http raw: server/discover (2026-07-28)")
    code, body = post(port, {"jsonrpc": "2.0", "id": 4, "method": "tools/list", "params": {"_meta": meta("2099-01-01")}},
                      {"MCP-Protocol-Version": "2099-01-01", "Mcp-Method": "tools/list"})
    check(code == 400 and body["error"]["code"] == -32022, "http raw: unknown version -> 400 -32022")
    code, body = post(port, {"jsonrpc": "2.0", "id": 5, "method": "tools/list", "params": {"_meta": meta()}},
                      {"MCP-Protocol-Version": MODERN, "Mcp-Method": "tools/call"})
    check(code == 400 and body["error"]["code"] == -32020, "http raw: header mismatch -> 400 -32020")


def wait_listening(port, proc, seconds=60):
    end = time.time() + seconds
    while time.time() < end:
        if proc.poll() is not None:
            return False
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                return True
        except OSError:
            time.sleep(0.25)
    return False


def stdio_raw():
    """Every legacy version by initialize, and a modern request, over one stdio process."""
    proc = subprocess.Popen(server_cmd("--mcp-stdio"), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, text=True)
    first = None
    for i, v in enumerate(LEGACY):
        proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": i, "method": "initialize", "params": {"protocolVersion": v}}) + "\n")
        proc.stdin.flush()
        line = proc.stdout.readline()
        first = first or line
        check(json.loads(line)["result"]["protocolVersion"] == v, f"stdio raw: initialize {v} echoed")
    proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 9, "method": "server/discover", "params": {"_meta": meta()}}) + "\n")
    proc.stdin.flush()
    check(MODERN in json.loads(proc.stdout.readline())["result"]["supportedVersions"], "stdio raw: server/discover")
    check(first.startswith("{"), "stdio raw: standard output starts with a message, not the banner")
    proc.stdin.close()
    try:
        proc.wait(timeout=20)
        check(True, "stdio raw: the server exits when standard input closes")
    except subprocess.TimeoutExpired:
        proc.kill()
        check(False, "stdio raw: the server exits when standard input closes")


async def main():
    port = free_port()
    http = subprocess.Popen(server_cmd(f"--mcp-port={port}"), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        check(wait_listening(port, http), f"http: the server listens on {port}")
        url = f"http://127.0.0.1:{port}/mcp"
        await sdk_client(url, "auto", "streamable http (auto)", MODERN)
        await sdk_client(url, "legacy", "streamable http (legacy)", "2025-11-25")
        await sse(port)
        raw_http(port)
    finally:
        http.terminate()
        http.wait(timeout=20)
    params = StdioServerParameters(command=GODOT, args=server_cmd("--mcp-stdio")[1:])
    await sdk_client(params, "auto", "stdio (auto)", MODERN)
    await sdk_client(params, "legacy", "stdio (legacy)", "2025-11-25")
    stdio_raw()
    print(f"\n[interop] {len(failures)} failed")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    asyncio.run(main())
