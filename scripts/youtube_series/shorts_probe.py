#!/usr/bin/env python3
"""Explore the app by hand before scripting a take: starts ActionTakeUITests on
the Shorts phone and serves a local port for one action at a time.

    OS3D_VIDEO_SIM=os3d-shorts … shorts_probe.py OUTDIR [port]
    curl -s localhost:8939/act -d 'palette_label:Sketch/Rectangle'
    curl -s localhost:8939/py -d 'a.fit(); print(a.mode())'     # actions.A as `a`
    curl -s 'localhost:8939/shot?name=01-ground'                 # → OUTDIR/01-ground.png
    curl -s localhost:8939/act -d finish
"""
import contextlib, io, os, subprocess, sys, traceback
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs
from common import *
import actions
from PIL import Image

OUT = sys.argv[1]
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8939
os.makedirs(OUT, exist_ok=True)
udid = udid_for()
simctl("terminate", udid, BUNDLE, check=False)
control = Control()
test = start_test(udid, os.path.join(OUT, "xcodebuild.log"), "ActionTakeUITests")
control.wait_event("ready", 900)
log("ready")
a = actions.A(Take(control, None))
scope = {"a": a, "actions": actions, "call": call, "json": __import__("json")}


def shot(name):
    p = os.path.join(OUT, name + ".png")
    simctl("io", udid, "screenshot", p)
    im = Image.open(p)
    if ORIENTATION == "landscape":
        im = im.transpose(Image.ROTATE_90)
    im.thumbnail((900, 900))
    im.save(p)
    return p


class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def reply(self, text):
        b = text.encode()
        self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        q = parse_qs(urlparse(self.path).query)
        self.reply(shot(q.get("name", ["shot"])[0]))

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        path = urlparse(self.path).path
        if path == "/act":
            if body == "finish":
                control.finish(); self.reply("finishing")
                threading.Thread(target=lambda: (time.sleep(1), server.shutdown()), daemon=True).start()
                return
            self.reply(control.act(body, 60))
        elif path == "/py":
            buf = io.StringIO()
            try:
                with contextlib.redirect_stdout(buf):
                    exec(body, scope)
            except Exception:
                buf.write(traceback.format_exc())
            self.reply(buf.getvalue())


server = HTTPServer(("127.0.0.1", PORT), H)
server.serve_forever()
try:
    test.wait(timeout=60)
except subprocess.TimeoutExpired:
    test.kill()
control.server.shutdown()
