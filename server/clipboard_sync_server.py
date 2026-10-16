"""
Listens for POSTs from the iOS Shortcut and sets the Windows clipboard to the
received text. Auth is a shared token (query string ?token=... or header
X-Token) so random devices on the LAN can't write to your clipboard.

Run: python clipboard_sync_server.py
"""

import ctypes
import json
import os
import re
import subprocess
import tempfile
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, unquote

import clippip_store as store
import clippip_links as links
import prompt_transforms as transforms

PORT = 5051
def _load_token() -> str:
    """The shared token lives in clippip_secrets.json next to this file ({"token": "..."}), never in the code."""
    try:
        with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "clippip_secrets.json"), encoding="utf-8") as fh:
            return str(json.load(fh)["token"])
    except (OSError, ValueError, KeyError):
        return os.environ.get("CLIPPIP_TOKEN", "change-me")


TOKEN = _load_token()   # use the same value in the phone app and the Shortcut

PDF_FILELIST_DIR = (r"C:\Users\Zoro_\Documents local backup of HDD\00 image lists and prompts"
                     r"\temp file lists\pdf text files")
PDF_FILENAMES_SETTING = os.path.join(os.path.dirname(__file__), "pdf_from_filenames.json")
# Matches NAI filenames: end in s-<seed> optionally followed by .png/.jpg/.jpeg
# Covers both truncated names (s-1290957405) and full names (s-1290957405.png)
NAI_LINE_RE  = re.compile(r's-\d+(?:\.(?:png|jpe?g)(?:\s*\(\d+\))?)?\s*$', re.I)
# Windows absolute path: C:\, D:\, etc. -- must never divert these to pdf dir
WIN_ABS_RE   = re.compile(r'^[A-Za-z]:[/\\]')


def pdf_from_filenames_enabled() -> bool:
    try:
        with open(PDF_FILENAMES_SETTING, encoding="utf-8") as fh:
            return bool(json.load(fh).get("enabled", True))
    except (OSError, ValueError, TypeError):
        return True


def set_pdf_from_filenames_enabled(enabled: bool) -> None:
    with open(PDF_FILENAMES_SETTING, "w", encoding="utf-8") as fh:
        json.dump({"enabled": bool(enabled)}, fh)


def looks_like_phone_filelist(text: str) -> bool:
    """True only for multi-line NAI filename lists shared from the phone.

    Guards (all must pass):
      - 3+ non-empty lines  (1-2 filenames go to clipboard, never diverted)
      - Every line ends in a NAI seed hash (s-<digits>), with or without .png
      - No Windows absolute paths like C:\\... (those stay on clipboard)
    """
    lines = [l.strip() for l in text.splitlines() if l.strip()]
    if len(lines) < 3:
        return False
    return all(
        NAI_LINE_RE.search(l) and not WIN_ABS_RE.match(l)
        for l in lines
    )


import ctypes.wintypes as wt

_u32 = ctypes.WinDLL("user32", use_last_error=True)
_k32 = ctypes.WinDLL("kernel32", use_last_error=True)
_GMEM_MOVEABLE = 0x0002
_CF_UNICODETEXT = 13

_u32.OpenClipboard.argtypes = [wt.HWND]
_u32.OpenClipboard.restype = wt.BOOL
_u32.EmptyClipboard.restype = wt.BOOL
_u32.CloseClipboard.restype = wt.BOOL
_u32.SetClipboardData.argtypes = [wt.UINT, wt.HANDLE]
_u32.SetClipboardData.restype = wt.HANDLE

_k32.GlobalAlloc.argtypes = [wt.UINT, ctypes.c_size_t]
_k32.GlobalAlloc.restype = wt.HGLOBAL
_k32.GlobalLock.argtypes = [wt.HGLOBAL]
_k32.GlobalLock.restype = ctypes.c_void_p
_k32.GlobalUnlock.argtypes = [wt.HGLOBAL]
_k32.GlobalUnlock.restype = wt.BOOL



def set_windows_clipboard(text: str) -> None:
    """Set the Windows clipboard text natively via Win32 API (<1ms vs 500ms powershell.exe)."""
    try:
        data = (text + "\x00").encode("utf-16-le")
        h_mem = _k32.GlobalAlloc(_GMEM_MOVEABLE, len(data))
        if not h_mem:
            raise OSError("GlobalAlloc failed")
        ptr = _k32.GlobalLock(h_mem)
        if not ptr:
            _k32.GlobalFree(h_mem)
            raise OSError("GlobalLock failed")
        try:
            ctypes.memmove(ptr, data, len(data))
        finally:
            _k32.GlobalUnlock(h_mem)

        for _ in range(15):
            if _u32.OpenClipboard(None):
                break
            time.sleep(0.02)
        else:
            raise OSError("OpenClipboard failed")

        try:
            _u32.EmptyClipboard()
            if not _u32.SetClipboardData(_CF_UNICODETEXT, h_mem):
                raise OSError("SetClipboardData failed")
        finally:
            _u32.CloseClipboard()
    except Exception as exc:
        # Fallback to PowerShell if Win32 API fails for any reason
        print(f"[clipboard] native set failed ({exc}), falling back to PowerShell")
        env = os.environ.copy()
        env["CLIP_SYNC_TEXT"] = text
        subprocess.run(
            ["powershell", "-NoProfile", "-Command", "Set-Clipboard -Value $env:CLIP_SYNC_TEXT"],
            env=env,
            check=True,
            capture_output=True,
            creationflags=subprocess.CREATE_NO_WINDOW,
        )



def set_windows_clipboard_image(image_bytes: bytes) -> None:
    fd, path = tempfile.mkstemp(suffix=".png")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(image_bytes)
        env = os.environ.copy()
        env["CLIP_SYNC_IMG_PATH"] = path
        subprocess.run(
            ["powershell", "-NoProfile", "-Command",
             "Add-Type -AssemblyName System.Windows.Forms,System.Drawing; "
             "$img = [System.Drawing.Image]::FromFile($env:CLIP_SYNC_IMG_PATH); "
             "[System.Windows.Forms.Clipboard]::SetImage($img); $img.Dispose()"],
            env=env,
            check=True,
            capture_output=True,
            creationflags=subprocess.CREATE_NO_WINDOW,
        )
    finally:
        os.remove(path)


def get_windows_clipboard() -> str:
    result = subprocess.run(
        ["powershell", "-NoProfile", "-Command", "Get-Clipboard -Raw"],
        check=True,
        capture_output=True,
        creationflags=subprocess.CREATE_NO_WINDOW,
    )
    return result.stdout.decode("utf-8", errors="replace").rstrip("\r\n")


def get_windows_clipboard_utf8() -> str:
    # Same as get_windows_clipboard but forces UTF-8 stdout so non-ASCII text survives.
    result = subprocess.run(
        ["powershell", "-NoProfile", "-Command",
         "[Console]::OutputEncoding=[Text.Encoding]::UTF8; Get-Clipboard -Raw"],
        check=True,
        capture_output=True,
        creationflags=subprocess.CREATE_NO_WINDOW,
    )
    return result.stdout.decode("utf-8", errors="replace").rstrip("\r\n")


POLL_MAX_CHARS = 200000
_poll_cache = {"seq": -1, "payload": {"changed": False}}
_poll_lock = threading.Lock()
# What the phone itself last put on the PC clipboard, so it is not sent straight back to the phone.
_echo = {"sha": None, "seq": -1, "image_at": 0.0}


def clipboard_seq() -> int:
    """Windows bumps this number on every clipboard change; reading it is nearly free."""
    return store.clipboard_seq()


def _save_clip_safe(**kw):
    """Storing a clip must never break the clipboard sync itself."""
    try:
        return store.save_clip(**kw)
    except Exception as exc:
        print(f"[store] save failed: {exc!r}")
        return None


_blocked_log = deque(maxlen=40)   # the latest PC clips kept off the phone, shown on the exclusions page

# GET /pc/exclude/ui : one page to switch the exclusions, edit their lists and block apps.
EXCLUDE_PAGE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ClipPiP exclusions</title>
<style>
:root { color-scheme: dark; }
body { margin: 0; padding: 14px 16px 40px; background: #111418; color: #e8eaed; font: 16px/1.4 -apple-system, "Segoe UI", sans-serif; }
h1 { font-size: 20px; margin: 4px 0 2px; } h2 { font-size: 15px; margin: 22px 0 6px; color: #9fb4c9; }
p.hint { margin: 2px 0 8px; color: #8b949e; font-size: 13px; }
.row { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 11px 12px; background: #1b2026; border-radius: 10px; margin-bottom: 6px; }
.row small { display: block; color: #8b949e; font-size: 12px; }
button { font: inherit; border: 0; border-radius: 8px; padding: 8px 12px; background: #2b3540; color: #e8eaed; }
button.on { background: #1f7a4d; } button.off { background: #4a2f33; } button.go { background: #2d5d9f; }
.chips { display: flex; flex-wrap: wrap; gap: 6px; }
.chip { background: #1b2026; border-radius: 16px; padding: 6px 10px; font-size: 14px; display: flex; gap: 8px; align-items: center; word-break: break-all; }
.chip button { padding: 0 6px; background: none; color: #f08a8a; font-size: 16px; }
.chip.app { background: #232b35; }
.add { display: flex; gap: 6px; margin-top: 6px; } .add input { flex: 1; min-width: 0; font: inherit; padding: 8px 10px; border-radius: 8px; border: 1px solid #2b3540; background: #0c0f12; color: #e8eaed; }
.recent div { padding: 7px 0; border-bottom: 1px solid #1f262d; font-size: 13px; word-break: break-all; } .recent b { color: #e0b46a; font-weight: 600; }
#msg { position: fixed; left: 12px; right: 12px; bottom: 12px; padding: 10px 12px; border-radius: 10px; background: #2d5d9f; display: none; }
</style></head><body>
<h1>ClipPiP exclusions</h1>
<p class="hint">PC copies that match are not stored and not sent to the phone. Changes apply at once.</p>
<h2>Kinds of clips</h2><div id="toggles"></div>
<h2>Paths that always pass</h2><p class="hint">A path or copied file containing one of these is never excluded.</p>
<div class="chips" id="allow_paths"></div><div class="add"><input id="in_allow_paths" placeholder="\folder name"><button data-add="allow_paths">Add</button></div>
<h2>Blocked apps</h2><p class="hint">App exe name, or part of a window title or page url.</p>
<div class="chips" id="blocked"></div><div class="add"><input id="in_app" placeholder="dopus.exe"><button id="add_app">Block</button></div>
<p class="hint" style="margin-top:10px">Recent PC clip sources, tap to block:</p><div class="chips" id="apps"></div>
<h2>Blocked text</h2><p class="hint">Clips containing one of these.</p>
<div class="chips" id="text"></div><div class="add"><input id="in_text" placeholder="some words"><button data-add="text">Add</button></div>
<h2>Blocked patterns (regex)</h2>
<div class="chips" id="regex"></div><div class="add"><input id="in_regex" placeholder="^\d+$"><button data-add="regex">Add</button></div>
<h2>Old clips</h2><p class="hint">Hide clips already in the Library that these rules would stop. Nothing is deleted.</p>
<div class="row"><span id="old">not checked</span><span><button id="old_check">Check</button> <button id="old_hide" class="go">Hide them</button></span></div>
<h2>Recently kept off the phone</h2><div class="recent" id="recent"></div>
<div id="msg"></div>
<script>
const token = new URLSearchParams(location.search).get("token") || "";
const LABELS = { file_paths: ["File path text", "text that is only file paths"],
                 copied_files: ["Copied files", "files copied in Explorer or DOpus, also single image files"],
                 logs: ["Logs and errors", "tracebacks, error text, terminal output"],
                 commands: ["Commands and code", "shell commands (git, python, cd ...) and code snippets"],
                 searches: ["Everything searches", "search strings copied from Everything"] };
const $ = id => document.getElementById(id);
function el(tag, cls, text) { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }
function say(text) { const m = $("msg"); m.textContent = text; m.style.display = "block"; clearTimeout(say.t); say.t = setTimeout(() => m.style.display = "none", 2200); }
async function call(path, params) {
  const q = new URLSearchParams(Object.assign({ token }, params || {}));
  const r = await fetch(path + "?" + q.toString());
  const data = await r.json().catch(() => ({}));
  if (!r.ok) { say(data.error || ("error " + r.status)); return null; }
  return data;
}
function chips(box, values, onRemove, cls) {
  box.replaceChildren();
  if (!values.length) box.append(el("span", "hint", "none"));
  for (const v of values) { const c = el("span", "chip" + (cls || ""), v); const x = el("button", "", "x"); x.onclick = () => onRemove(v); c.append(x); box.append(c); }
}
function render(d) {
  if (!d) return;
  const t = $("toggles"); t.replaceChildren();
  for (const key of Object.keys(LABELS)) {
    const row = el("div", "row"); const left = el("div", "", LABELS[key][0]); left.append(el("small", "", LABELS[key][1]));
    const on = !!d.exclude[key]; const b = el("button", on ? "on" : "off", on ? "Blocked" : "Allowed");
    b.onclick = async () => render(await call("/pc/exclude", { set: key, on: "toggle" }));
    row.append(left, b); t.append(row);
  }
  for (const key of ["allow_paths", "text", "regex"])
    chips($(key), d.exclude[key], async v => render(await call("/pc/exclude", { list: key, remove: v })));
  chips($("blocked"), d.blocked_apps, async v => { await call("/pc/block", { remove: v }); load(); });
  const apps = $("apps"); apps.replaceChildren();
  for (const a of d.apps.filter(a => !d.blocked_apps.includes(a.app))) {
    const c = el("button", "chip app", a.app + " (" + a.clips + ")"); c.onclick = () => blockApp(a.app); apps.append(c);
  }
  const rec = $("recent"); rec.replaceChildren();
  if (!d.recent.length) rec.append(el("p", "hint", "nothing since the server started"));
  for (const r of d.recent) { const line = el("div"); line.append(el("b", "", r.ts + "  " + r.rule + (r.app ? "  (" + r.app + ")" : "")), el("div", "", r.preview)); rec.append(line); }
  if (d.old) $("old").textContent = d.old.hidden ? ("hid " + d.old.count + " clips") : (d.old.count + " old clips match");
}
async function blockApp(name) { if (!name.trim()) return; await call("/pc/block", { add: name.trim() }); say("Blocked " + name); load(); }
async function load() { render(await call("/pc/exclude")); }
document.querySelectorAll("button[data-add]").forEach(b => b.onclick = async () => {
  const key = b.dataset.add, box = $("in_" + key); if (!box.value.trim()) return;
  const d = await call("/pc/exclude", { list: key, add: box.value }); if (d) { box.value = ""; render(d); }
});
$("add_app").onclick = () => { blockApp($("in_app").value); $("in_app").value = ""; };
$("old_check").onclick = async () => render(await call("/pc/exclude", { hide_old: "preview" }));
$("old_hide").onclick = async () => { if (confirm("Hide the matching old clips from the phone?")) render(await call("/pc/exclude", { hide_old: "apply" })); };
load();
</script></body></html>
"""


def _note_blocked(why: str, app: str, item: dict) -> None:
    files = [f for f in item.get("files") or [] if f]
    what = (item.get("text") or "").strip() or (files[0] if files else f"[{item.get('kind')}]")
    _blocked_log.appendleft({"ts": time.strftime("%H:%M:%S"), "rule": why, "app": app or "",
                             "preview": " ".join(what.split())[:120]})
    print(f"[blocked] pc clip from {app!a} (rule {why!a})")


def _read_pc_clip(seq: int):
    """Read the PC clipboard natively and store it. None = clipboard busy, try again on the next poll."""
    if seq == _echo["seq"]:
        return {"changed": False}
    item = store.read_clipboard(allow_files=bool(store.load_config().get("send_copied_image_files", True)))
    if item is None:
        return None
    why = store.exclude_reason(item)
    if why:
        _note_blocked(why, store.clipboard_source().get("source_app", ""), item)
        return {"changed": False}
    if item["kind"] == "none":
        return {"changed": False}
    sha = store.content_sha(item["kind"], item["text"], item["data"])
    if sha == _echo["sha"] or (item["kind"] == "image" and time.time() - _echo["image_at"] < 4):
        return {"changed": False}
    _echo["sha"] = sha
    if item["kind"] == "text" and looks_like_server_log(item["text"]):
        return {"changed": False}
    source = store.clipboard_source()
    hit = store.source_blocked(source, item["source_url"])
    if hit:
        _note_blocked("app: " + hit, source["source_app"], item)
        return {"changed": False}
    clip_id = _save_clip_safe(direction="pc_to_ios", kind=item["kind"], text=item["text"], data=item["data"],
                              ext=item["ext"], source_url=item["source_url"], source_file=item["source_file"],
                              **source)
    if item["kind"] == "text":
        return {"changed": True, "kind": "text", "text": item["text"][:POLL_MAX_CHARS], "id": clip_id}
    if clip_id is None:
        return {"changed": False}  # an image can only be fetched by id
    print(f"[to-phone] image id={clip_id} bytes={len(item['data'])}")
    return {"changed": True, "kind": "image", "id": clip_id, "bytes": len(item["data"])}


def poll_payload(client_seq: int, wait: float = 0.0) -> dict:
    """For the iOS app: one native clipboard read per change. With wait > 0 the answer is held (long poll,
    checked every 50 ms with a cheap sequence-number call) until the clipboard changes or the wait ends."""
    seq = clipboard_seq()
    if wait > 0 and client_seq >= 0 and seq == client_seq and store.load_config().get("pc_to_phone_enabled", True):
        deadline = time.time() + min(wait, 8.0)
        while seq == client_seq and time.time() < deadline:
            time.sleep(0.05)
            seq = clipboard_seq()
    if not store.load_config().get("pc_to_phone_enabled", True):
        # Switched off: the PC clipboard is not even read. Copies made meanwhile are skipped for good.
        return {"seq": seq, "changed": False, "paused": True}
    if seq == client_seq or client_seq < 0:
        # A freshly started app only learns the current number: it gets what is copied from now on.
        return {"seq": seq, "changed": False}
    with _poll_lock:
        if _poll_cache["seq"] != seq:
            payload = _read_pc_clip(seq)
            if payload is None:
                return {"seq": client_seq, "changed": False}
            _poll_cache["seq"] = seq
            _poll_cache["payload"] = payload
        return dict(_poll_cache["payload"], seq=seq)


def parse_post_text(raw_body: str, content_type: str) -> str:
    if "application/json" in content_type:
        value = json.loads(raw_body).get("text", "")
        return "\r\n".join(map(str, value)) if isinstance(value, list) else str(value)
    if "application/x-www-form-urlencoded" in content_type:
        values = parse_qs(raw_body, keep_blank_values=True).get("text", [""])
        return "\r\n".join(values)
    return raw_body


def preview(text: str, limit: int = 180) -> str:
    one_line = text.replace("\r", "\\r").replace("\n", "\\n")
    return one_line if len(one_line) <= limit else one_line[:limit] + "..."


def looks_like_server_log(text: str) -> bool:
    return (
        "Listening on 0.0.0.0:5051" in text
        and "HTTP/1.1" in text
        and ("[received]" in text or "POST /set?token=" in text)
    )


class Handler(BaseHTTPRequestHandler):
    def _authorized(self) -> bool:
        query_token = parse_qs(urlparse(self.path).query).get("token", [None])[0]
        header_token = self.headers.get("X-Token")
        return TOKEN in (query_token, header_token)

    def do_POST(self):
        if not self._authorized():
            self.send_response(401)
            self.end_headers()
            self.wfile.write(b"unauthorized")
            return

        length = int(self.headers.get("Content-Length", 0))
        raw_bytes = self.rfile.read(length)
        content_type = self.headers.get("Content-Type", "")

        post_path = urlparse(self.path).path
        if post_path in ("/lib/rename", "/lib/delete", "/lib/activate", "/lib/block", "/lib/file"):
            self._lib_edit(post_path, raw_bytes)
            return

        if post_path == "/transform":
            self._transform(raw_bytes)
            return

        if post_path == "/clip/push":
            self._clip_push(raw_bytes)
            return

        device = self.headers.get("X-Device", "")
        ios_types = self.headers.get("X-Clip-Types", "")[:1000]
        ios_url = self.headers.get("X-Clip-Url", "")
        # Which app the copy came from: sent percent-encoded by the app, see ClipMonitor.swift.
        hint = lambda name, limit: unquote(self.headers.get(name, "") or "", errors="replace")[:limit]
        ios_src = store.ios_source(ios_types, ios_url, hosts=hint("X-Clip-Hosts", 400),
                                   origin=hint("X-Clip-Origin", 120), origin_name=hint("X-Clip-Origin-Name", 80),
                                   app=hint("X-Clip-App", 80))
        probe = hint("X-Clip-Probe", 3000)
        if probe:  # the app sends this once per launch: what the phone's clipboard object exposes
            print(f"[origin-probe] {probe!a}", flush=True)
            try:  # its own small file: stdout is buffered and lost on a restart
                with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "origin_probe.log"), "a",
                          encoding="utf-8") as fh:
                    fh.write(time.strftime("%Y-%m-%d %H:%M:%S ") + ascii(probe)
                             + " origin=" + ascii(hint("X-Clip-Origin", 120)) + "\n")
            except OSError:
                pass
        if content_type.startswith("image/"):
            clip_id = None
            if raw_bytes:
                ext = "." + content_type.split("/", 1)[1].split(";")[0].strip().lower().replace("jpeg", "jpg")
                clip_id = _save_clip_safe(direction="ios_to_pc", kind="image", data=raw_bytes, ext=ext, device=device,
                                          source_url=ios_url, ios_types=ios_types, **ios_src)
            try:
                _echo["image_at"] = time.time()
                set_windows_clipboard_image(raw_bytes)
                _echo["image_at"] = time.time()
                _echo["seq"] = clipboard_seq()
                self.send_response(200)
                if clip_id is not None:
                    self.send_header("X-Clip-Id", str(clip_id))
                self.end_headers()
                self.wfile.write(b"ok (image)")
                print(f"[received] image Content-Type={content_type!r} bytes={len(raw_bytes)}")
            except subprocess.CalledProcessError as e:
                self.send_response(500)
                self.end_headers()
                self.wfile.write(str(e).encode())
            return

        raw_body = raw_bytes.decode("utf-8", errors="replace")
        text = parse_post_text(raw_body, content_type)

        print(f"[received] Content-Type={content_type!r} raw_len={len(raw_body)} text_len={len(text)} text_preview={preview(text)!r}")

        if looks_like_server_log(text):
            self.send_response(409)
            self.end_headers()
            self.wfile.write(b"refusing server log clipboard loop")
            print("[rejected] looks like clipboard sync server log")
            return

        clip_id = None
        if text.strip():
            clip_id = _save_clip_safe(direction="ios_to_pc", kind="text", text=text, device=device,
                                      source_url=ios_url, ios_types=ios_types, **ios_src)
            # links copied on the phone go to the local browsing history server as well
            links.forward(text, direction="ios_to_pc",
                          source_app=ios_src.get("source_app", ""), device=device)

        if pdf_from_filenames_enabled() and looks_like_phone_filelist(text):
            os.makedirs(PDF_FILELIST_DIR, exist_ok=True)
            txt_path = os.path.join(PDF_FILELIST_DIR, f"clipboard_{int(time.time())}.txt")
            with open(txt_path, "w", encoding="utf-8") as fh:
                fh.write(text.strip() + "\n")
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok (filepath list -> pdf text files)")
            print(f"[filepath-list] wrote {txt_path}")
            return

        try:
            _echo["sha"] = store.content_sha("text", text)
            set_windows_clipboard(text)
            _echo["seq"] = clipboard_seq()
            self.send_response(200)
            if clip_id is not None:
                self.send_header("X-Clip-Id", str(clip_id))
            self.end_headers()
            self.wfile.write(b"ok")
        except subprocess.CalledProcessError as e:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(str(e).encode())

    def do_GET(self):
        if not self._authorized():
            self.send_response(401)
            self.end_headers()
            self.wfile.write(b"unauthorized")
            return

        if urlparse(self.path).path == "/pdf-filenames":
            body = json.dumps({"ok": True, "enabled": pdf_from_filenames_enabled()}).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if urlparse(self.path).path == "/poll":
            query = parse_qs(urlparse(self.path).query)
            try:
                client_seq = int(query.get("seq", ["-1"])[0])
            except ValueError:
                client_seq = -1
            try:
                wait = float(query.get("wait", ["0"])[0])
            except ValueError:
                wait = 0.0
            body = json.dumps(poll_payload(client_seq, wait)).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        path = urlparse(self.path).path
        query = parse_qs(urlparse(self.path).query)

        def arg(name, default=""):
            return query.get(name, [default])[0]

        if path == "/transforms":
            self._send(200, json.dumps({"transforms": transforms.registry(),
                                        "groups": transforms.GROUP_LABELS}).encode("utf-8"),
                       "application/json; charset=utf-8")
            return

        if path == "/lib/tabs":
            self._send(200, json.dumps({"tabs": store.lib_tabs()}).encode("utf-8"), "application/json; charset=utf-8")
            return

        if path == "/lib/items":
            try:
                result = store.lib_items(arg("tab", store.HISTORY_TAB), arg("q"), int(arg("offset", "0") or 0),
                                         int(arg("limit", "100") or 100), force=arg("refresh") == "1",
                                         tag=arg("tag"), kind=arg("kind"))
                self._send(200, json.dumps(result).encode("utf-8"), "application/json; charset=utf-8")
            except KeyError:
                self._send(404, b'{"error":"unknown tab"}', "application/json")
            except ValueError:
                self._send(400, b'{"error":"bad number"}', "application/json")
            except Exception as e:
                self._send(503, json.dumps({"error": str(e)}).encode("utf-8"), "application/json; charset=utf-8")
            return

        if path == "/pc/receive":
            # ?on=1 | 0 | toggle   (no "on" = just report). Usable from an iOS Shortcut or a PC hotkey.
            enabled = bool(store.load_config().get("pc_to_phone_enabled", True))
            want = arg("on").lower()
            if want in ("1", "0", "true", "false", "on", "off", "toggle"):
                enabled = (not enabled) if want == "toggle" else want in ("1", "true", "on")
                store.save_config(pc_to_phone_enabled=enabled)
                print(f"[pc/receive] pc clips to phone: {'on' if enabled else 'off'}")
            body = {"enabled": enabled, "message": "PC clips ON" if enabled else "PC clips OFF"}
            self._send(200, json.dumps(body).encode("utf-8"), "application/json; charset=utf-8")
            return

        if path == "/pc/block":
            # ?add=dopus.exe  ?remove=dopus.exe  (neither = just list)
            if arg("add") or arg("remove"):
                blocked = store.set_blocked(add=arg("add"), remove=arg("remove"))
                print(f"[pc/block] blocked sources now: {blocked!a}")
            else:
                blocked = store.blocked_sources()
            self._send(200, json.dumps({"blocked": blocked}).encode("utf-8"), "application/json; charset=utf-8")
            return

        if path == "/pc/exclude/ui":
            # The settings page for everything below, made for the phone's browser.
            self._send(200, EXCLUDE_PAGE.encode("utf-8"), "text/html; charset=utf-8")
            return

        if path == "/pc/exclude":
            # Which PC clips are kept off the phone. No arguments = just report.
            #   ?set=file_paths|copied_files|logs|commands|searches&on=1|0|toggle
            #   ?list=allow_paths|text|regex&add=...   or   &remove=...
            #   ?hide_old=preview|apply   (old clips today's rules would stop; apply hides them, nothing is deleted)
            reply = {}
            try:
                if arg("set"):
                    store.set_exclude_toggle(arg("set"), arg("on", "toggle").lower())
                if arg("list"):
                    store.edit_exclude_list(arg("list"), add=arg("add"), remove=arg("remove"))
                if arg("set") or arg("list"):
                    print(f"[pc/exclude] now: {ascii(store.exclude_config())}")
                if arg("hide_old") in ("preview", "apply"):
                    reply["old"] = store.hide_excluded(apply=arg("hide_old") == "apply")
            except KeyError:
                self._send(400, b'{"error":"unknown setting"}', "application/json")
                return
            except ValueError as e:
                self._send(400, json.dumps({"error": f"bad pattern: {e}"}).encode("utf-8"),
                           "application/json; charset=utf-8")
                return
            except Exception as e:
                self._send(503, json.dumps({"error": str(e)}).encode("utf-8"), "application/json; charset=utf-8")
                return
            reply.update(exclude=store.exclude_config(), blocked_apps=store.blocked_sources(),
                         apps=store.recent_pc_apps(), recent=list(_blocked_log))
            self._send(200, json.dumps(reply).encode("utf-8"), "application/json; charset=utf-8")
            return

        if path == "/lib/tags":
            try:
                body = json.dumps({"tags": store.lib_tags(arg("tab", "*"))}).encode("utf-8")
                self._send(200, body, "application/json; charset=utf-8")
            except KeyError:
                self._send(404, b'{"error":"unknown tab"}', "application/json")
            except Exception as e:
                self._send(503, json.dumps({"error": str(e)}).encode("utf-8"), "application/json; charset=utf-8")
            return

        if path in ("/clip/file", "/clip/thumb"):
            try:
                found = store.clip_file(int(arg("id", "0")), thumb=path == "/clip/thumb")
                if not found:
                    self._send(404, b"not found", "text/plain")
                    return
                with open(found[0], "rb") as fh:
                    self._send(200, fh.read(), found[1])
            except (ValueError, OSError):
                self._send(404, b"not found", "text/plain")
            return

        if path == "/copyq/img":
            try:
                data = store.copyq_image(arg("tab"), int(arg("row", "0")))
            except (ValueError, OSError, subprocess.SubprocessError):
                data = None
            if data:
                self._send(200, data, "image/png")
            else:
                self._send(404, b"not found", "text/plain")
            return

        try:
            text = get_windows_clipboard()
            body = text.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except subprocess.CalledProcessError as e:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(str(e).encode())

    def do_PUT(self):
        if not self._authorized():
            self.send_response(401)
            self.end_headers()
            self.wfile.write(b"unauthorized")
            return
        if urlparse(self.path).path != "/pdf-filenames":
            self.send_response(404)
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", 0))
        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
            enabled = payload["enabled"]
            if not isinstance(enabled, bool):
                raise ValueError("enabled must be true or false")
            set_pdf_from_filenames_enabled(enabled)
            body = json.dumps({"ok": True, "enabled": enabled}).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (ValueError, KeyError, json.JSONDecodeError) as e:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(str(e).encode("utf-8"))

    def _lib_edit(self, path: str, raw: bytes) -> None:
        """POST /lib/rename {key, sig, name}, /lib/delete {key, sig, force}, /lib/activate {key, sig}.

        activate = put that stored clip on the PC clipboard (the phone tapped it).
        """
        def reply(code, obj):
            self._send(code, json.dumps(obj).encode("utf-8"), "application/json; charset=utf-8")
        try:
            req = json.loads(raw.decode("utf-8"))
            key, sig = str(req["key"]), str(req.get("sig", ""))
            if path == "/lib/rename":
                store.lib_rename(key, sig, str(req.get("name", "")))
            elif path == "/lib/block":
                reply(200, {"ok": True, "blocked": store.block_source_of(key)})
                return
            elif path == "/lib/file":
                done = store.lib_file(key, sig, str(req.get("dest", "")))
                print(f"[lib] {path} key={key!r} -> {req.get('dest')!r} {done}")
                reply(200, {"ok": True, "done": done})
                return
            elif path == "/lib/activate":
                content = store.lib_content(key, sig)
                if content["kind"] == "text":
                    _echo["sha"] = store.content_sha("text", content["text"])
                    set_windows_clipboard(content["text"])
                else:
                    _echo["image_at"] = time.time()
                    set_windows_clipboard_image(content["data"])
                    _echo["image_at"] = time.time()
                _echo["seq"] = clipboard_seq()
            else:
                store.lib_delete(key, sig, force=bool(req.get("force", False)))
            print(f"[lib] {path} key={key!r}")
            reply(200, {"ok": True})
        except store.ClipEditError as e:
            # pinned = pinned in CopyQ (ask again with force), changed = the clip is no longer what the phone shows
            reply(409, {"ok": False, "error": str(e)})
        except (KeyError, ValueError, TypeError):
            reply(404, {"ok": False, "error": "unknown clip"})
        except Exception as e:
            reply(500, {"ok": False, "error": "failed: " + str(e)[:200]})

    def _transform(self, raw: bytes) -> None:
        """POST /transform {action, text, start, end} -> {text, start, end, changed}.

        Pure text in, pure text out: nothing is stored and no clipboard is touched,
        so the phone's transform sheet can chain these and undo locally.
        """
        def reply(code, obj):
            self._send(code, json.dumps(obj).encode("utf-8"), "application/json; charset=utf-8")
        try:
            req = json.loads(raw.decode("utf-8"))
            result = transforms.apply(str(req["action"]), req.get("text", ""),
                                      req.get("start"), req.get("end"))
            reply(200, {"ok": True, **result})
        except transforms.TransformError as e:
            reply(400, {"ok": False, "error": str(e)})
        except (KeyError, ValueError, TypeError, UnicodeDecodeError) as e:
            reply(400, {"ok": False, "error": f"bad request: {str(e)[:200]}"})
        except Exception as e:
            reply(500, {"ok": False, "error": f"failed: {str(e)[:200]}"})

    def _clip_push(self, raw: bytes) -> None:
        """POST /clip/push {text, copy, save} -> commit transformed text.

        copy = put it on the PC clipboard (echo guarded, so it does not come
        straight back as a new PC clip), save = store it as a phone-side clip.
        """
        def reply(code, obj):
            self._send(code, json.dumps(obj).encode("utf-8"), "application/json; charset=utf-8")
        try:
            req = json.loads(raw.decode("utf-8"))
            text = req.get("text", "")
            if not isinstance(text, str) or not text.strip():
                reply(400, {"ok": False, "error": "no text"})
                return
            if len(text) > transforms.MAX_CHARS:
                reply(400, {"ok": False, "error": "text is too long"})
                return
            copy = bool(req.get("copy", True))
            save = bool(req.get("save", False))
            clip_id = None
            if save:
                clip_id = _save_clip_safe(direction="ios_to_pc", kind="text", text=text,
                                          device=self.headers.get("X-Device", ""),
                                          source_app="clippip", source_title="transformed")
            if copy:
                _echo["sha"] = store.content_sha("text", text)
                set_windows_clipboard(text)
                _echo["seq"] = clipboard_seq()
            print(f"[push] copy={copy} save={save} len={len(text)} preview={preview(text)!r}")
            reply(200, {"ok": True, "clip_id": clip_id, "copied": copy, "saved": save})
        except (KeyError, ValueError, TypeError, UnicodeDecodeError) as e:
            reply(400, {"ok": False, "error": f"bad request: {str(e)[:200]}"})
        except subprocess.CalledProcessError as e:
            reply(500, {"ok": False, "error": f"clipboard failed: {str(e)[:200]}"})
        except Exception as e:
            reply(500, {"ok": False, "error": f"failed: {str(e)[:200]}"})

    def _send(self, code: int, body: bytes, content_type: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        # The app polls once a second and loads thumbnails in bulk: logging those would grow the log forever.
        if getattr(self, "path", "").startswith(("/poll", "/clip/thumb")):
            return
        print(format % args)


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"Listening on 0.0.0.0:{PORT} (token required)")
    server.serve_forever()

