"""Live test of the new routes on a THROWAWAY port.

Nothing real is touched: the Windows clipboard setter and the clip store are
replaced in-process, and link capture is pointed at a fake capture server on
another throwaway port instead of the real browsing history server on 8770.
"""
import json
import os
import sys
import threading
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SRC = r"C:\Users\Zoro_\Documents local backup of HDD\00000 python scripts\clipboard_sync"
sys.path.insert(0, SRC)

import clipboard_sync_server as srv  # noqa: E402
import clippip_links as links        # noqa: E402

PORT = 0             # let Windows pick a free port: never the live 5051
CAPTURE_PORT = 0     # same, never the live 8770
TOKEN = srv.TOKEN

# ---- stub out everything that would touch the real machine ----
clipboard = []
srv.set_windows_clipboard = lambda text: clipboard.append(text)
srv.clipboard_seq = lambda: 1
saved = []


def fake_save(**kw):
    saved.append(kw)
    return 999


srv._save_clip_safe = fake_save
srv.store.content_sha = lambda kind, text=None, data=None: "sha"

captured = []


class CaptureHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        captured.append(json.loads(self.rfile.read(n).decode("utf-8")))
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *a):
        pass


cap = ThreadingHTTPServer(("127.0.0.1", CAPTURE_PORT), CaptureHandler)
CAPTURE_PORT = cap.server_address[1]
threading.Thread(target=cap.serve_forever, daemon=True).start()
links.settings = lambda: {**links.DEFAULTS,
                          "endpoint": f"http://127.0.0.1:{CAPTURE_PORT}/capture",
                          "dedupe_minutes": 60}

httpd = ThreadingHTTPServer(("127.0.0.1", PORT), srv.Handler)
PORT = httpd.server_address[1]
threading.Thread(target=httpd.serve_forever, daemon=True).start()

BASE = f"http://127.0.0.1:{PORT}"
fails = []


def check(label, cond, detail=""):
    if not cond:
        fails.append(f"{label}: {detail}")


def req(path, payload=None, method=None, expect=200):
    url = f"{BASE}{path}" + ("&" if "?" in path else "?") + f"token={TOKEN}"
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    r = urllib.request.Request(url, data=data, method=method or ("POST" if data else "GET"),
                               headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(r, timeout=10) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode("utf-8"))


# ---- GET /transforms ----
code, body = req("/transforms")
check("transforms status", code == 200, code)
check("transforms count", len(body["transforms"]) == len(srv.transforms.TRANSFORMS), body)
check("transforms have groups", all(t["group_label"] for t in body["transforms"]))

# unauthorized is refused
try:
    urllib.request.urlopen(f"{BASE}/transforms", timeout=5)
    fails.append("auth: /transforms served without a token")
except urllib.error.HTTPError as e:
    check("auth 401 GET", e.code == 401, e.code)

# ---- POST /transform ----
code, body = req("/transform", {"action": "prefixSource", "text": "ass grab, kissing"})
check("transform status", code == 200, (code, body))
check("transform result", body["text"] == "source#ass grab, source#kissing", body)
check("transform changed", body["changed"] is True, body)

code, body = req("/transform", {"action": "wrapOnly", "text": "1girl, solo, smile",
                                "start": 7, "end": 11})
check("selection respected", body["text"] == "1girl, ||solo||, smile", body)
check("selection caret", (body["start"], body["end"]) == (7, 15), body)

code, body = req("/transform", {"action": "moveDown", "text": "a\nb\nc", "start": 0, "end": 0})
check("document transform", body["text"] == "b\na\nc", body)

code, body = req("/transform", {"action": "nope", "text": "x"})
check("unknown action 400", code == 400 and not body["ok"], (code, body))
code, body = req("/transform", {"text": "x"})
check("missing action 400", code == 400, (code, body))
code, body = req("/transform", {"action": "wrapOnly", "text": "x" * 20001})
check("too long 400", code == 400 and "long" in body["error"], (code, body))

# non-ascii survives the round trip
code, body = req("/transform", {"action": "prefixSource", "text": "\u521d\u97f3\u30df\u30af"})
check("non ascii", body["text"] == "source#\u521d\u97f3\u30df\u30af", body)

# nothing was stored or copied by a transform
check("transform stores nothing", not saved, saved)
check("transform copies nothing", not clipboard, clipboard)

# ---- POST /clip/push ----
code, body = req("/clip/push", {"text": "source#ass grab", "copy": True, "save": False})
check("push status", code == 200 and body["ok"], (code, body))
check("push copied", clipboard == ["source#ass grab"], clipboard)
check("push did not save", not saved, saved)

code, body = req("/clip/push", {"text": "saved one", "copy": False, "save": True})
check("push saved", len(saved) == 1 and saved[0]["text"] == "saved one", saved)
check("push save returns id", body["clip_id"] == 999, body)
check("push did not copy", len(clipboard) == 1, clipboard)

code, body = req("/clip/push", {"text": "   ", "copy": True})
check("blank text 400", code == 400, (code, body))
code, body = req("/clip/push", {"text": "x" * 20001})
check("push too long 400", code == 400, (code, body))

# ---- link forwarding ----
links.forward("look at this https://www.reddit.com/r/test/comments/abc/post_title/",
              direction="ios_to_pc", source_app="reddit", device="iPhone")
links._q.join()
check("one link captured", len(captured) == 1, captured)
if captured:
    c = captured[0]
    check("link url", c["current_url"].endswith("/post_title/"), c)
    check("link context", c["context"] == "clippip", c)
    check("link tags", "reddit" in c["source_tags"] and "clippip" in c["source_tags"], c)

# the same url twice is sent once
links.forward("https://www.reddit.com/r/test/comments/abc/post_title/")
links._q.join()
check("dedupe", len(captured) == 1, captured)

# title picked up from the line above the link
links.forward("Some Post Title\nhttps://example.com/article/one")
links._q.join()
check("title from text", captured[-1]["title"] == "Some Post Title", captured[-1])

# two links in one clip
links.forward("a https://example.com/x1 and https://example.com/x2")
links._q.join()
check("two links", len(captured) == 4, len(captured))

# PC clips are not forwarded while ios_only is on
before = len(captured)
links.forward("https://example.com/pc-side", direction="pc_to_ios")
check("pc side skipped", len(captured) == before, captured[-1] if captured else None)

# no url, no capture; junk never raises
for text in ("", "   ", "1girl, solo", "C:\\Users\\Zoro_\\file.png", "ftp://x.com/a",
             "http://a", None):
    check(f"no url {text!r}", links.forward(text or "") == [])

# a dead capture server must not raise
links.settings = lambda: {**links.DEFAULTS, "endpoint": "http://127.0.0.1:9/capture",
                          "timeout": 0.5, "dedupe_minutes": 0}
links.forward("https://example.com/dead-server")
links._q.join()
check("dead server survived", True)

# one worker thread, no thread churn
threads = [t for t in threading.enumerate() if t.name == "clippip-links"]
check("single worker", len(threads) == 1, len(threads))

httpd.shutdown()
cap.shutdown()
print(f"endpoint + link tests: {len(fails)} failures")
for f in fails:
    print("  " + f)
sys.exit(1 if fails else 0)
