"""Live A2A 1.0 interop against a running Godot listener (a2a.gd). Not collected by pytest.

Start the listener in a window (no --headless):
  godot --path . --script res://tests/serve.gd -- --mcp-port=8799
Run (a2a-sdk[http-server]==1.3.0 installed; ADAPTER_DIR is a checkout of V-Sekai-fire/a2a-mcp-adapter
with its requirements.lock installed, or unset to run only the SDK checks):
  A2A_URL=http://127.0.0.1:8799 ADAPTER_DIR=/path/to/a2a-mcp-adapter python tests/interop_a2a.py
"""
import asyncio
import os
import sys

URL = os.environ.get("A2A_URL", "http://127.0.0.1:8799")
ADAPTER_DIR = os.environ.get("ADAPTER_DIR", "")
results = []


def check(name, ok, detail=""):
    results.append(bool(ok))
    print(("PASS " if ok else "FAIL ") + name + (f"  [{detail}]" if detail else ""))


async def sdk_checks():
    from a2a.client import ClientConfig, create_client
    from a2a.helpers.proto_helpers import new_text_message
    from a2a.types import a2a_pb2 as pb

    client = await create_client(URL, client_config=ClientConfig(streaming=False))

    async def send(msg):
        last = None
        async for ev in client.send_message(pb.SendMessageRequest(message=msg)):
            last = ev
        return last

    def user(text):
        m = new_text_message(text)
        m.role = pb.Role.ROLE_USER
        return m

    ev = await send(user("call get_scene_tree"))
    task = ev.task if ev is not None and ev.HasField("task") else None
    check("S1 SDK SendMessage returns a task", task is not None, str(ev)[:100].replace("\n", " "))
    if task is not None:
        check("S2 task COMPLETED", task.status.state == pb.TaskState.TASK_STATE_COMPLETED)
        check("S3 artifact carries the scene", "Interop" in str(task.artifacts), str(task.artifacts)[:80].replace("\n", " "))
    ev2 = await send(user("tools"))
    check("S4 SDK 'tools' lists tools", ev2 is not None and "get_scene_tree" in str(ev2))
    ev3 = await send(user("call no_such_tool"))
    t3 = ev3.task if ev3 is not None and ev3.HasField("task") else None
    check("S5 unknown tool REJECTED", t3 is not None and t3.status.state == pb.TaskState.TASK_STATE_REJECTED)
    if task is not None:
        got = await client.get_task(pb.GetTaskRequest(id=task.id))
        check("S6 SDK GetTask", got.id == task.id)
    listed = await client.list_tasks(pb.ListTasksRequest())
    check("S7 SDK ListTasks", len(listed.tasks) >= 3, f"{len(listed.tasks)} tasks")


async def adapter_checks():
    sys.path.insert(0, ADAPTER_DIR)
    os.environ["A2A_ALLOW_PRIVATE_AGENTS"] = "1"
    import a2a_mcp_server as srv
    import a2a_v1
    from fastmcp import Client

    c = a2a_v1.A2AV1Client(URL)
    res = await c.send_message("call get_scene_tree")
    t = res.get("task", {})
    check("A1 adapter client SendMessage", t.get("status", {}).get("state") == "TASK_STATE_COMPLETED", str(res)[:100])
    got = await c.get_task(t["id"])
    check("A2 adapter client GetTask", got.get("id") == t["id"])
    srv.registered_agents[URL] = srv.AgentInfo(url=URL, name="godot", description="d")
    async with Client(srv.mcp) as mc:
        out = await mc.call_tool("send_message", {"agent_url": URL, "message": "call get_scene_tree"})
        data = out.data if out.data is not None else out.structured_content
    flat = str(data)
    check("A3 MCP tool result succeeds", data.get("status") == "success", flat[:100])
    check("A4 Godot text is inside the envelope", "<<UNTRUSTED_AGENT_REPLY" in flat and "Interop" in flat)


async def main():
    await sdk_checks()
    if ADAPTER_DIR:
        await adapter_checks()
    print(f"\n{sum(results)}/{len(results)} passed")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
