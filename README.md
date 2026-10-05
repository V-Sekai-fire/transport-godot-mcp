# transport-godot-mcp

An MCP server inside the Godot editor and the running game, so an MCP client can inspect and drive both.

## What it is for

The editor plugin answers what a scene was authored as, and the runtime script answers what the scene is while it plays. An MCP client reaches either one over local HTTP. It is the second host in a two-implementation interop check against another engine's MCP editor plugin.

## Build and run

Open this repository in the Godot editor, where the addon is already enabled. To use it in another project, copy the addon into that project's `addons/` directory and enable it there. A game that should answer while it plays adds `addons/vsekai_godot_mcp/mcp_runtime.gd` as an autoload itself. The `addon-root` branch holds only the addon directory, for projects that vendor it as a subtree.

## Licence

MIT; see `LICENSE`.
