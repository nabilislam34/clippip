"""Handle/memory regression check for the new routes: 200 real requests."""
import json
import os
import subprocess
import sys
import threading
import urllib.request
from http.server import ThreadingHTTPServer

SRC = r"C:\Users\Zoro_\Documents local backup of HDD\00000 python scripts\clipboard_sync"
sys.path.insert(0, SRC)
import clipboard_sync_server as srv  # noqa: E402
import clippip_links as links        # noqa: E402

srv.set_windows_clipboard = lambda text: None
srv.clipboard_seq = lambda: 1
srv._save_clip_safe = lambda **kw: 1
srv.store.content_sha = lambda kind, text=None, data=None: "sha"
links.settings = lambda: {**links.DEFAULTS, "enabled": False}

httpd = ThreadingHTTPServer(("127.0.0.1", 0), srv.Handler)
port = httpd.server_address[1]
threading.Thread(target=httpd.serve_forever, daemon=True).start()
PID = os.getpid()
BASE = f"http://127.0.0.1:{port}"


def stats():
    out = subprocess.run(["powershell", "-NoProfile", "-Command",
                          f"$p=Get-Process -Id {PID}; "
                          "[pscustomobject]@{h=$p.HandleCount;ws=[int]($p.WorkingSet64/1MB);"
                          "t=$p.Threads.Count} | ConvertTo-Json"],
                         capture_output=True, text=True)
    return json.loads(out.stdout)


def hit(path, payload):
    body = json.dumps(payload).encode("utf-8")
    r = urllib.request.Request(f"{BASE}{path}?token={srv.TOKEN}", data=body, method="POST",
                               headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(r, timeout=10) as resp:
        resp.read()


TEXT = "0.6::sciamano240::, 1girl, solo, source#ass grab, smile, long hair"
ACTIONS = ["prefixSource", "swapSourceTarget", "pipesWrap", "commaToNL", "weightUp",
           "dedupeTags", "insertCommas", "neg2"]

for _ in range(10):      # warm up
    hit("/transform", {"action": "prefixTarget", "text": TEXT})
before = stats()

for i in range(200):
    hit("/transform", {"action": ACTIONS[i % len(ACTIONS)], "text": TEXT})
    urllib.request.urlopen(f"{BASE}/transforms?token={srv.TOKEN}", timeout=10).read()
    hit("/clip/push", {"text": TEXT, "copy": True, "save": False})

after = stats()
httpd.shutdown()
print(f"600 requests (200x /transform + 200x /transforms + 200x /clip/push)")
print(f"  handles {before['h']} -> {after['h']}")
print(f"  working set {before['ws']} MB -> {after['ws']} MB")
print(f"  threads {before['t']} -> {after['t']}")
