#!/usr/bin/env python3
"""MCP server exposing the openshape3d DEBUG agent bridge to Claude Desktop.

`AgentServer.swift` named this file from the day it was written; this is it.

WHY THIS EXISTS AT ALL: Claude Code needs nothing here — it has a shell, so
`curl` is a complete client and `.claude/skills/drive-openshape3d/` is the whole
integration. Claude Desktop has no shell, so it needs a real MCP server. That is
the only difference between the two clients.

WHY IT IS STDLIB-ONLY: it runs inside Claude Desktop's launch environment, not
yours — no venv, no PATH you control, no chance to `pip install` when something
is missing. A dependency here is a support burden paid in "it just says failed"
reports. Hand-rolling JSON-RPC over stdio costs ~120 lines and removes that
whole class of problem. Targets Python 3.9 (the system interpreter on macOS):
no `match`, no PEP-604 unions.

This server holds NO logic of its own. Every tool is a thin call to the same
HTTP endpoints the skill documents, so the two clients cannot drift apart.

Register it in ~/Library/Application Support/Claude/claude_desktop_config.json:

    {"mcpServers": {"openshape3d": {
        "command": "python3",
        "args": ["/absolute/path/to/scripts/mcp_openshape3d.py"]}}}

Then launch the app with OS3D_AGENT=1 — see docs/AGENT_CONTROL.md.
"""

import base64
import json
import os
import sys
import urllib.error
import urllib.request

HOST = os.environ.get("OS3D_AGENT_HOST", "127.0.0.1")
PORT = os.environ.get("OS3D_AGENT_PORT", "8787")
BASE = "http://{}:{}".format(HOST, PORT)
TIMEOUT = 30

PROTOCOL_VERSION = "2025-06-18"
SERVER_INFO = {"name": "openshape3d", "version": "1.0.0"}


# --------------------------------------------------------------------------
# HTTP to the app
# --------------------------------------------------------------------------

def call_app(method, path, payload=None):
    """Return (status, body_bytes, content_type). Never raises for HTTP errors —
    the bridge's 4xx bodies carry the actionable message, so they must reach the
    model intact rather than being flattened into a transport failure."""
    url = BASE + path
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    if data is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            return response.status, response.read(), response.headers.get("Content-Type", "")
    except urllib.error.HTTPError as error:
        return error.code, error.read(), error.headers.get("Content-Type", "")
    except urllib.error.URLError as error:
        raise RuntimeError(
            "Cannot reach openshape3d at {}: {}. The app has to be running a DEBUG "
            "build launched with OS3D_AGENT=1. See docs/AGENT_CONTROL.md.".format(BASE, error.reason)
        )


def text_result(body):
    return {"content": [{"type": "text", "text": body}]}


def error_result(message):
    return {"content": [{"type": "text", "text": message}], "isError": True}


# --------------------------------------------------------------------------
# Tools
# --------------------------------------------------------------------------

TOOLS = [
    {
        "name": "os3d_health",
        "description": (
            "Check whether openshape3d is running and reachable. Returns the platform "
            "(simulator/maccatalyst/device), the bound port, and whether a document is "
            "open. Call this first — everything else fails without it."
        ),
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "os3d_list_commands",
        "description": (
            "List every command that can actually be run. Call before os3d_run_command "
            "rather than guessing an id — the app's full catalog is wider than this, and "
            "the extra entries have no entry point yet."
        ),
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "os3d_state",
        "description": (
            "Read the editor: current mode, selection, every body with its volume in mm3 "
            "and whether it is still analytic (brep), undo/redo availability, and the "
            "measurement rows shown in the app's info bar. Verify geometry with this, not "
            "with a screenshot — an image cannot show that a boolean produced a 0 mm3 body."
        ),
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "os3d_run_command",
        "description": (
            "Run a named command, e.g. 'view.isometric', 'edit.undo', 'model.extrude'. "
            "Note that tool commands ARM a tool (they put the editor in that mode); they do "
            "not parameterize or commit it. A result of ran=false means the command is real "
            "but does not apply in the current mode — read the message rather than retrying."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {"id": {"type": "string", "description": "Command id from os3d_list_commands."}},
            "required": ["id"],
        },
    },
    {
        "name": "os3d_screenshot",
        "description": (
            "Capture the 3D viewport as a PNG, rendered by the app itself. After any view.* "
            "command, wait about a second before calling this: standard views animate, and an "
            "immediate capture catches the camera mid-flight."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "width": {"type": "integer", "description": "Pixels, 64-4096. Default 1024."},
                "height": {"type": "integer", "description": "Pixels, 64-4096. Default 1024."},
            },
        },
    },
]


def run_tool(name, arguments):
    if name == "os3d_health":
        status, body, _ = call_app("GET", "/v1/health")
        return text_result(body.decode("utf-8"))

    if name == "os3d_list_commands":
        status, body, _ = call_app("GET", "/v1/commands")
        return text_result(body.decode("utf-8"))

    if name == "os3d_state":
        status, body, _ = call_app("GET", "/v1/state")
        return text_result(body.decode("utf-8"))

    if name == "os3d_run_command":
        command_id = (arguments or {}).get("id")
        if not command_id:
            return error_result("os3d_run_command needs an 'id'. Call os3d_list_commands for the list.")
        status, body, _ = call_app("POST", "/v1/command", {"id": command_id})
        text = body.decode("utf-8")
        # A 4xx here is a usable answer (unknown id / no entry point / no
        # document), so pass the body through and only flag it as an error.
        return error_result(text) if status >= 400 else text_result(text)

    if name == "os3d_screenshot":
        arguments = arguments or {}
        width = int(arguments.get("width", 1024))
        height = int(arguments.get("height", 1024))
        status, body, content_type = call_app(
            "GET", "/v1/screenshot?w={}&h={}".format(width, height))
        if status >= 400 or "image/png" not in content_type:
            return error_result(body.decode("utf-8", "replace"))
        return {"content": [{
            "type": "image",
            "data": base64.b64encode(body).decode("ascii"),
            "mimeType": "image/png",
        }]}

    return error_result("Unknown tool: {}".format(name))


# --------------------------------------------------------------------------
# JSON-RPC over stdio
# --------------------------------------------------------------------------

def handle(message):
    """Return a response dict, or None for a notification."""
    method = message.get("method")
    message_id = message.get("id")

    # Notifications (no id) get no reply — answering one is a protocol error.
    if message_id is None:
        return None

    if method == "initialize":
        requested = (message.get("params") or {}).get("protocolVersion")
        return ok(message_id, {
            "protocolVersion": requested or PROTOCOL_VERSION,
            "capabilities": {"tools": {}},
            "serverInfo": SERVER_INFO,
        })

    if method == "ping":
        return ok(message_id, {})

    if method == "tools/list":
        return ok(message_id, {"tools": TOOLS})

    if method == "tools/call":
        params = message.get("params") or {}
        try:
            return ok(message_id, run_tool(params.get("name"), params.get("arguments")))
        except RuntimeError as error:
            # The app being down is the single most common failure and is
            # recoverable by the user, so report it as tool output rather than
            # as a transport error the model cannot see the text of.
            return ok(message_id, error_result(str(error)))
        except Exception as error:  # noqa: BLE001 — never take the server down
            return ok(message_id, error_result("openshape3d MCP server error: {!r}".format(error)))

    return {"jsonrpc": "2.0", "id": message_id,
            "error": {"code": -32601, "message": "Method not found: {}".format(method)}}


def ok(message_id, result):
    return {"jsonrpc": "2.0", "id": message_id, "result": result}


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        response = handle(message)
        if response is not None:
            sys.stdout.write(json.dumps(response) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
