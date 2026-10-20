#!/usr/bin/env python3
"""A real MCP client for `scripts/mcp_openshape3d.py` — JSON-RPC 2.0 over
the server's stdio, the way Claude Desktop and Claude Code talk to it. Every
call is logged (name, arguments, the reply's text or image size, seconds) so
a session can be written up afterwards (`transcript_markdown`).

    from mcp_client import MCPClient
    with MCPClient(port=8947, log_dir="run") as mcp:
        mcp.initialize()
        print(mcp.tool_names())
        state = mcp.os3d("state")
        mcp.os3d("sketch.create", {"name": "Profile"})

Nothing here knows about the app's HTTP endpoints: the server does, and the
point of driving the server rather than curl is to exercise the same tool
surface an assistant gets.
"""
import base64
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(os.path.dirname(HERE), "mcp_openshape3d.py")


class MCPError(RuntimeError):
    def __init__(self, op, text):
        super().__init__("{}: {}".format(op, text[:400]))
        self.op = op
        self.text = text
        try:
            self.body = json.loads(text)
        except ValueError:
            self.body = None


class MCPClient:
    def __init__(self, port=None, log_dir=None, server=SERVER, python=sys.executable):
        env = dict(os.environ)
        if port:
            env["OS3D_AGENT_PORT"] = str(port)
        self.log_dir = log_dir
        if log_dir:
            os.makedirs(log_dir, exist_ok=True)
            env["OS3D_MCP_LOG"] = os.path.join(log_dir, "mcp_server_calls.jsonl")
        self.process = subprocess.Popen([python, server], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        env=env, text=True, bufsize=1)
        self.n = 0
        self.calls = []          # what a transcript is written from
        self.server_info = None
        self.instructions = None
        self.tools = []

    # ---- protocol ----------------------------------------------------------

    def rpc(self, method, params=None):
        self.n += 1
        message = {"jsonrpc": "2.0", "id": self.n, "method": method, "params": params or {}}
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError("the MCP server closed its stdout")
        reply = json.loads(line)
        if reply.get("id") != self.n:
            raise RuntimeError("out-of-order reply: {}".format(reply)[:200])
        if "error" in reply:
            raise MCPError(method, json.dumps(reply["error"]))
        return reply["result"]

    def notify(self, method, params=None):
        message = {"jsonrpc": "2.0", "method": method, "params": params or {}}
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def initialize(self):
        result = self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                         "clientInfo": {"name": "scan-to-cad", "version": "1.0"}})
        self.notify("notifications/initialized")
        self.server_info = result.get("serverInfo")
        self.instructions = result.get("instructions", "")
        self.tools = self.rpc("tools/list")["tools"]
        return result

    def tool_names(self):
        return [t["name"] for t in self.tools]

    # ---- the one tool --------------------------------------------------------

    def call(self, name, arguments=None, note=None):
        """A tools/call; returns (result, parsed) where parsed is the JSON the
        text content held (or the text itself, or image bytes). Raises
        MCPError when the tool reports isError."""
        started = time.time()
        result = self.rpc("tools/call", {"name": name, "arguments": arguments or {}})
        seconds = time.time() - started
        texts = [c.get("text", "") for c in result.get("content", []) if c.get("type") == "text"]
        images = [c for c in result.get("content", []) if c.get("type") == "image"]
        text = "".join(texts)
        parsed = None
        if images:
            parsed = base64.b64decode(images[0]["data"])
        else:
            try:
                parsed = json.loads(text)
            except ValueError:
                parsed = text
        entry = {"t": started, "seconds": round(seconds, 3), "name": name, "arguments": arguments or {},
                 "isError": bool(result.get("isError")), "note": note,
                 "reply": text[:4000] if not images else "<image {} bytes {}>".format(
                     len(parsed), images[0].get("mimeType"))}
        self.calls.append(entry)
        if self.log_dir:
            with open(os.path.join(self.log_dir, "mcp_client_calls.jsonl"), "a") as f:
                f.write(json.dumps(entry) + "\n")
        if result.get("isError"):
            raise MCPError("{} {}".format(name, (arguments or {}).get("op", "")), text)
        return result, parsed

    def os3d(self, op, args=None, note=None):
        """`os3d {op, args}` → the parsed reply (a dict for JSON replies, bytes
        for a picture). A feature that was recorded but did not build raises."""
        arguments = {"op": op}
        if args:
            arguments["args"] = args
        _, parsed = self.call("os3d", arguments, note=note)
        if isinstance(parsed, dict) and parsed.get("failed"):
            raise MCPError(op, parsed.get("message", json.dumps(parsed)))
        return parsed

    # ---- write-up -------------------------------------------------------------

    def transcript_markdown(self, title="MCP session"):
        lines = ["# " + title, ""]
        if self.server_info:
            lines.append("Server: `{}` {} — {} tool(s) listed: {}".format(
                self.server_info.get("name"), self.server_info.get("version"), len(self.tools),
                ", ".join("`{}`".format(n) for n in self.tool_names())))
            lines.append("")
        lines.append("| # | op | arguments | seconds | reply |")
        lines.append("|---|---|---|---|---|")
        for i, c in enumerate(self.calls, 1):
            args = dict(c["arguments"])
            op = args.pop("op", c["name"])
            inner = args.pop("args", args)
            arg_text = json.dumps(inner, separators=(",", ":"))
            if len(arg_text) > 160:
                arg_text = arg_text[:157] + "…"
            reply = c["reply"]
            summary = reply
            try:
                body = json.loads(reply)
                keys = []
                for key in ("sketchID", "producedBodyIDs", "changedBodyIDs", "bodyIDs", "volumeMM3", "fileName",
                            "sizeMM", "triangles", "overallIoU", "invalid", "ran", "hasDocument", "failed", "error"):
                    if key in body:
                        value = body[key]
                        if isinstance(value, list):
                            value = [v[:8] if isinstance(v, str) else v for v in value]
                        elif isinstance(value, str):
                            value = value[:8] if key.endswith("ID") else value
                        elif isinstance(value, float):
                            value = round(value, 3)
                        keys.append("{}={}".format(key, json.dumps(value)))
                if "bodies" in body and isinstance(body["bodies"], list):
                    keys.append("bodies={}".format(len(body["bodies"])))
                summary = ", ".join(keys) or reply[:80]
            except (ValueError, TypeError):
                pass
            if c.get("note"):
                summary = "{} — {}".format(c["note"], summary)
            summary = summary.replace("|", "\\|")
            if len(summary) > 200:
                summary = summary[:197] + "…"
            lines.append("| {} | `{}` | `{}` | {:.2f} | {}{} |".format(
                i, op, arg_text.replace("|", "\\|"), c["seconds"], "ERROR: " if c["isError"] else "", summary))
        total = sum(c["seconds"] for c in self.calls)
        lines += ["", "{} calls, {:.1f} s in the app.".format(len(self.calls), total), ""]
        return "\n".join(lines)

    # ---- lifecycle --------------------------------------------------------------

    def close(self):
        try:
            self.process.stdin.close()
            self.process.wait(timeout=5)
        except Exception:
            self.process.kill()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False
