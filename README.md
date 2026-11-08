# transport-godot-mcp

An MCP server inside the Godot editor and the running game, so an MCP client can inspect and drive both.

## What it is for

The editor plugin answers what a scene was authored as, and the runtime script answers what the scene is while it plays. An MCP client reaches either one over local HTTP, and the running game also over stdio or, in a web export, from the page. It is the second host in a two-implementation interop check against another engine's MCP editor plugin.

## Build and run

Open this repository in the Godot editor, where the addon is already enabled. To use it in another project, copy the addon into that project's `addons/` directory and enable it there. A game that should answer while it plays adds `addons/vsekai_godot_mcp/mcp_runtime.gd` as an autoload itself. The `addon-root` branch holds only the addon directory, for projects that vendor it as a subtree.

## Transports and versions

The running game serves one tool list on every transport its platform has:

- Streamable HTTP at `http://127.0.0.1:8789/mcp`, and the older HTTP+SSE pair (`GET /sse`, then `POST /messages`) on the same port. Set the port with `-- --mcp-port=N` or `GODOT_MCP_PORT`; 0 turns HTTP off.
- stdio, with `--quiet ... -- --mcp-stdio`. The game quits when the client closes standard input.

The same listener also answers A2A 1.0 (JSON-RPC): the agent card at `/.well-known/agent-card.json` and `POST /`. A message names a tool, either as a data part `{"tool": name, "arguments": {...}}` or as text (`tools`, `call <tool> [json]`), and the reply is a finished task. `a2a.gd` has the details; streaming and push are off. HTTP refuses any request that carries an `Origin` header (403), because only a web page sends one and a page could otherwise run tools such as `run_script` in the editor; MCP SDKs and CLIs send none. A game that serves a browser client sets `vsekai_godot_mcp/origin_policy` to `localhost` or `off`. A2A always refuses an Origin.

Protocol versions 2024-11-05, 2025-03-26, 2025-06-18 and 2025-11-25 start with `initialize`. Version 2026-07-28 has no handshake: each request names its version, and `server/discover` lists the versions.

A game trims the built-in tools and adds its own in Project Settings: `vsekai_godot_mcp/allow`, `vsekai_godot_mcp/providers`, `vsekai_godot_mcp/server_name`, `vsekai_godot_mcp/instructions` and `vsekai_godot_mcp/listen_by_default`. `mcp_runtime.gd` describes each one.

## Tests

`pixi run test` runs the headless Godot tests. `pixi run interop` connects the official MCP Python SDK to the runtime over each transport and each protocol version.

## Licence

MIT; see `LICENSE`.
