"""
ClipPiP laptop side, used by clipboard_sync_server.py:
  - native Windows clipboard reads (text, image, source app/title/url)
  - clip store: every clip is one file plus one row in a SQLite db
  - CopyQ tab browser + search for the phone app

Store dir (override with env CLIPPIP_STORE_DIR for tests):
  <dir>\\clippip_clips.sqlite
  <dir>\\clips\\YYYY-MM\\<yyyymmdd_hhmmss>_<id>_<ios|pc>.<txt|png|jpg>
  <dir>\\thumbs\\<id>.jpg
"""

import ctypes
import ctypes.wintypes as wt
import hashlib
import io
import json
import os
import re
import sqlite3
import subprocess
import threading
import time
from contextlib import closing
from datetime import datetime

try:
    from PIL import BmpImagePlugin, Image
except ImportError:  # images are skipped without Pillow, text still works
    Image = None

STORE_DIR = os.environ.get("CLIPPIP_STORE_DIR") or (
    r"C:\Users\Zoro_\Documents local backup of HDD\00000 ditto clips database\clipPip ios clips")
DB_PATH = os.path.join(STORE_DIR, "clippip_clips.sqlite")
CONFIG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "clippip_config.json")
COPYQ_EXE = r"C:\Program Files\CopyQ\copyq.exe"

MAX_TEXT_CHARS = 200000
MAX_IMAGE_BYTES = 30 * 1024 * 1024
IMAGE_EXTS = (".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp")
COPYQ_TTL = 120          # seconds a cached CopyQ tab is served before a background refresh
HISTORY_TAB = "history"
CLIPBOARD_MANAGERS = ("copyq.exe", "ditto.exe", "powershell.exe", "pwsh.exe")

DEFAULT_CONFIG = {
    # "tab" is the exact CopyQ tab name (with its & accelerator), "label" is what the phone shows,
    # "parent" is the tab this one is nested under (its parent's "tab" value) so the phone can group them.
    "copyq_tabs": [
        {"tab": "temp", "label": "temp"},
        {"tab": "chars/char 2", "label": "char 2"},
        {"tab": "mixes", "label": "mixes"},
        {"tab": "mixes/new mixes", "label": "new mixes", "parent": "mixes"},
        {"tab": "mixes/v5 mixes", "label": "v5 mixes", "parent": "mixes"},
        {"tab": "mixes/others mixes", "label": "others mixes", "parent": "mixes"},
        {"tab": "mixes/v3 mixes", "label": "v3 mixes", "parent": "mixes"},
        {"tab": "face&s", "label": "faces"},
        {"tab": "&clothes", "label": "clothes"},
        {"tab": "body wei&ghts", "label": "body weights"},
        {"tab": "artists", "label": "artists"},
        {"tab": "se&x acts", "label": "sex acts"},
        {"tab": "&clipboard", "label": "clipboard"},
        {"tab": "pr&ompt presets", "label": "prompt presets"},
        {"tab": "pr&ompt presets/main preset", "label": "main preset", "parent": "pr&ompt presets"},
        {"tab": "pr&ompt presets/new", "label": "new", "parent": "pr&ompt presets"},
        {"tab": "pr&ompt presets/v3 mixes", "label": "v3 mixes", "parent": "pr&ompt presets"},
        {"tab": "pr&ompt presets/frontal", "label": "frontal", "parent": "pr&ompt presets"},
        {"tab": "pr&ompt presets/ass", "label": "ass", "parent": "pr&ompt presets"},
        {"tab": "pr&ompt presets/uc", "label": "uc", "parent": "pr&ompt presets"},
        {"tab": "pr&ompt presets/uc/male uc", "label": "male uc", "parent": "pr&ompt presets/uc"},
        {"tab": "pr&ompt presets/uc/female uc", "label": "female uc", "parent": "pr&ompt presets/uc"},
        {"tab": "pr&ompt presets/negs", "label": "negs", "parent": "pr&ompt presets"},
        {"tab": "pr&ompt presets/group sex", "label": "group sex", "parent": "pr&ompt presets"},
        {"tab": "pr&ompt presets/male", "label": "male", "parent": "pr&ompt presets"},
        {"tab": "pr&ompt presets/female", "label": "female", "parent": "pr&ompt presets"},
        {"tab": "pr&ompt presets/background", "label": "background", "parent": "pr&ompt presets"},
        {"tab": "2 clipboar&d/test", "label": "test"},
        {"tab": "2 clipboar&d/test/test 2", "label": "test 2", "parent": "2 clipboar&d/test"},
        {"tab": "2 clipboar&d/test/2 clipboar&d\\todd prompts", "label": "todd prompts", "parent": "2 clipboar&d/test"},
        {"tab": "2 clipboar&d/test/2 clipboar&d\\todd prompts/2 clipboar&d\\todd prompts\\uc", "label": "uc", "parent": "2 clipboar&d/test/2 clipboar&d\\todd prompts"},
        {"tab": "2 clipboar&d/test/2 clipboar&d\\todd prompts\\girl text", "label": "girl text", "parent": "2 clipboar&d/test"},
        {"tab": "2 clipboar&d/test/shota", "label": "shota", "parent": "2 clipboar&d/test"},
        {"tab": "2 clipboar&d/test/shota/uc", "label": "uc", "parent": "2 clipboar&d/test/shota"},
        {"tab": "2 clipboar&d/test/shota/dialogue", "label": "dialogue", "parent": "2 clipboar&d/test/shota"},
    ],
    # Ditto clipboard-manager groups browsed read-only: "id" is Main.lID, "parent" nests a subgroup.
    "ditto_groups": [
        {"id": 3553, "label": "ditto artists"},
        {"id": 5010, "label": "ditto faces"},
        {"id": 394, "label": "ditto clothes"},
        {"id": 6283, "label": "ditto mixes"},
        {"id": 39215, "label": "v3 mixes", "parent": 6283},
        {"id": 372, "label": "ditto characters"},
        {"id": 5013, "label": "fate", "parent": 372},
        {"id": 5898, "label": "marvel", "parent": 372},
        {"id": 33786, "label": "request characters", "parent": 372},
    ],
    # A single image FILE copied on the laptop (DOpus/Explorer Ctrl+C) is sent to the phone as an image.
    "send_copied_image_files": True,
    # False = PC copies are not read, not stored and not sent to the phone (phone to PC keeps working).
    "pc_to_phone_enabled": True,
    # PC copies from these sources are ignored. An entry matches an app's exe name (dopus.exe)
    # or any part of the window title or page url (lowercase).
    "blocked_sources": [],
}

_config_lock = threading.Lock()
_config_cache = {"mtime": None, "cfg": None}


def load_config() -> dict:
    """The config file, re-read only when it changed on disk (the phone asks for it every second)."""
    try:
        mtime = os.stat(CONFIG_PATH).st_mtime_ns
    except OSError:
        mtime = -1
    with _config_lock:
        if _config_cache["cfg"] is not None and _config_cache["mtime"] == mtime:
            return _config_cache["cfg"]
        cfg = dict(DEFAULT_CONFIG)
        try:
            with open(CONFIG_PATH, encoding="utf-8") as fh:
                cfg.update(json.load(fh))
        except FileNotFoundError:
            try:
                with open(CONFIG_PATH, "w", encoding="utf-8") as fh:
                    json.dump(DEFAULT_CONFIG, fh, indent=2)
                mtime = os.stat(CONFIG_PATH).st_mtime_ns
            except OSError:
                pass
        except (OSError, ValueError):
            pass
        _config_cache["mtime"], _config_cache["cfg"] = mtime, cfg
        return cfg


def save_config(**changes) -> dict:
    """Change some keys of the config file, keeping everything else in it."""
    with _config_lock:
        try:
            with open(CONFIG_PATH, encoding="utf-8") as fh:
                on_disk = json.load(fh)
        except (OSError, ValueError):
            on_disk = dict(DEFAULT_CONFIG)
        on_disk.update(changes)
        tmp = CONFIG_PATH + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(on_disk, fh, indent=2)
        os.replace(tmp, CONFIG_PATH)
        _config_cache["cfg"] = None
    return load_config()


def blocked_sources() -> list:
    return [str(x).strip().lower() for x in load_config().get("blocked_sources", []) if str(x).strip()]


def set_blocked(add: str = "", remove: str = "") -> list:
    current = blocked_sources()
    add, remove = add.strip().lower(), remove.strip().lower()
    if add and add not in current:
        current.append(add)
    if remove:
        current = [x for x in current if x != remove]
    save_config(blocked_sources=current)
    return current


def source_blocked(source: dict, url: str = "") -> str:
    """The matching block entry, or '' when this source is allowed."""
    apps = {(source.get("source_app") or "").lower(), (source.get("owner_app") or "").lower()}
    where = ((source.get("source_title") or "") + "\n" + (url or "")).lower()
    for entry in blocked_sources():
        if entry in apps or entry in where:
            return entry
    return ""


# ---------------------------------------------------------------- exclusions (PC clips kept off the phone)

# Config key "exclude". A PC copy that matches is not stored and not sent to the phone.
DEFAULT_EXCLUDE = {
    "file_paths": True,      # text that is nothing but file paths
    "copied_files": True,    # files copied in Explorer / DOpus (a copied image file is otherwise sent as an image)
    "logs": False,           # error logs, tracebacks, terminal output
    "commands": False,       # shell commands and code (same rule as the sorter's "commands and code" tab)
    "searches": False,       # Everything searches (same rule as the sorter's "everything searches" tab)
    # A path containing one of these (lowercase) is never excluded by file_paths / copied_files.
    "allow_paths": ["\\nai gens", "\\a personal work\\"],
    "text": [],              # clips containing one of these texts
    "regex": [],             # clips matching one of these patterns (case ignored)
}
EXCLUDE_TOGGLES = ("file_paths", "copied_files", "logs", "commands", "searches")
EXCLUDE_LISTS = ("allow_paths", "text", "regex")
_PATH_LINE_RE = re.compile(r'^"?(?:[A-Za-z]:[\\/]|\\\\[\w.$-]+\\|file://)\S.*$')
_LOG_RE = re.compile(      # same rule as clippip_ai.py
    r"Traceback \(most recent call last\)|^\s*File \".+\", line \d+|\b\w*(?:Error|Exception):\s"
    r"|^\s*at .+\(.+:\d+:\d+\)|\bHTTP/1\.[01]\"? \d{3}\b|^\[?\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}"
    r"|\b(?:ERROR|WARN(?:ING)?|FATAL|DEBUG)\b[:\]]|^PS [A-Z]:\\|^\s*\$ \w+|^\s*>>> ", re.M)
_REGEX_SCAN_CHARS = 20000


def exclude_config() -> dict:
    saved = load_config().get("exclude")
    cfg = {k: (list(v) if isinstance(v, list) else v) for k, v in DEFAULT_EXCLUDE.items()}
    if isinstance(saved, dict):
        for key in EXCLUDE_TOGGLES:
            if key in saved:
                cfg[key] = bool(saved[key])
        for key in EXCLUDE_LISTS:
            if isinstance(saved.get(key), list):
                cfg[key] = [str(x) for x in saved[key] if str(x).strip()]
    return cfg


def set_exclude_toggle(key: str, want: str) -> dict:
    """want = "1" | "0" | "toggle"."""
    if key not in EXCLUDE_TOGGLES:
        raise KeyError(key)
    cfg = exclude_config()
    cfg[key] = (not cfg[key]) if want == "toggle" else want in ("1", "true", "on")
    save_config(exclude=cfg)
    return exclude_config()


def edit_exclude_list(key: str, add: str = "", remove: str = "") -> dict:
    if key not in EXCLUDE_LISTS:
        raise KeyError(key)
    cfg = exclude_config()
    add, remove = add.strip()[:300], remove.strip()
    if key == "allow_paths":
        add, remove = add.lower(), remove.lower()
    if add and key == "regex":
        try:
            re.compile(add)
        except re.error as exc:      # a broken pattern is refused here
            raise ValueError(str(exc)) from None
    if add and add not in cfg[key]:
        cfg[key].append(add)
    if remove:
        cfg[key] = [x for x in cfg[key] if x != remove]
    save_config(exclude=cfg)
    return exclude_config()


def exclude_reason(item: dict) -> str:
    """Why a PC clip is kept off the phone, or '' when it may go.
    item = {"kind", "text", "files"}; files = the paths of a file copy (Explorer / DOpus)."""
    cfg = exclude_config()
    allow = [a.lower() for a in cfg["allow_paths"]]

    def allowed(path: str) -> bool:
        low = path.lower()
        return any(a in low for a in allow)

    files = item.get("files") or []
    if cfg["copied_files"] and files and not any(f and allowed(f) for f in files):
        return "copied files"
    text = (item.get("text") or "") if item.get("kind") == "text" else ""
    if not text:
        return ""
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if (cfg["file_paths"] and lines and all(_PATH_LINE_RE.match(line) for line in lines)
            and not any(allowed(line) for line in lines)):
        return "file path"
    if cfg["logs"] and _LOG_RE.search(text):
        return "log / error text"
    if cfg["commands"] or cfg["searches"]:
        try:
            import clippip_rules
            sort = clippip_rules.not_prompt(text, {})
        except Exception:
            sort = None
        if sort and cfg["commands"] and sort[0] == clippip_rules.COMMANDS:
            return sort[1]                                  # "command" or "code"
        if sort and cfg["searches"] and sort[0] == clippip_rules.SEARCHES:
            return "everything search"
    low = text.lower()
    for entry in cfg["text"]:
        if entry.lower() in low:
            return f"text: {entry}"
    head = text[:_REGEX_SCAN_CHARS]
    for pattern in cfg["regex"]:
        try:
            if re.search(pattern, head, re.I | re.M):
                return f"regex: {pattern}"
        except re.error:
            continue
    return ""


def recent_pc_apps(limit: int = 12) -> list:
    """The apps the latest PC clips came from, most used first (offered as one-tap blocks)."""
    try:
        with _db_lock, closing(_connect()) as con:
            rows = con.execute(
                "SELECT lower(source_app), count(*) FROM (SELECT source_app FROM clips WHERE direction = 'pc_to_ios' "
                "AND coalesce(source_app,'') != '' ORDER BY id DESC LIMIT 300) GROUP BY lower(source_app) "
                "ORDER BY count(*) DESC LIMIT ?", (limit,)).fetchall()
    except sqlite3.Error:
        return []
    return [{"app": app, "clips": n} for app, n in rows]


def hide_excluded(apply: bool = False) -> dict:
    """Old PC clips that today's exclusions and blocked apps would stop. apply = hide them from the phone
    (deleted_at is set; the rows and their files stay)."""
    hits = []
    with _db_lock, closing(_connect()) as con:
        rows = con.execute("SELECT id, kind, text, source_app, source_title, source_url, owner_app, source_file "
                           "FROM clips WHERE direction = 'pc_to_ios' AND deleted_at IS NULL")
        for cid, kind, text, app, title, url, owner, src_file in rows:
            why = source_blocked({"source_app": app, "source_title": title, "owner_app": owner}, url or "")
            why = ("app: " + why) if why else exclude_reason(
                {"kind": kind, "text": text or "", "files": [src_file] if src_file else []})
            if why:
                hits.append((cid, why))
        if apply and hits:
            now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            con.executemany("UPDATE clips SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL",
                            [(now, cid) for cid, _ in hits])
            con.commit()
    reasons = {}
    for _, why in hits:
        reasons[why] = reasons.get(why, 0) + 1
    return {"count": len(hits), "hidden": bool(apply and hits), "reasons": reasons}


# ---------------------------------------------------------------- native clipboard

_u32 = ctypes.WinDLL("user32", use_last_error=True)
_k32 = ctypes.WinDLL("kernel32", use_last_error=True)
_shell32 = ctypes.WinDLL("shell32", use_last_error=True)

_u32.OpenClipboard.argtypes = [wt.HWND]
_u32.OpenClipboard.restype = wt.BOOL
_u32.CloseClipboard.restype = wt.BOOL
_u32.GetClipboardData.argtypes = [wt.UINT]
_u32.GetClipboardData.restype = wt.HANDLE
_u32.IsClipboardFormatAvailable.argtypes = [wt.UINT]
_u32.IsClipboardFormatAvailable.restype = wt.BOOL
_u32.RegisterClipboardFormatW.argtypes = [wt.LPCWSTR]
_u32.RegisterClipboardFormatW.restype = wt.UINT
_u32.GetClipboardSequenceNumber.restype = wt.DWORD
_u32.GetClipboardOwner.restype = wt.HWND
_u32.GetForegroundWindow.restype = wt.HWND
_u32.GetWindowTextW.argtypes = [wt.HWND, wt.LPWSTR, ctypes.c_int]
_u32.GetWindowThreadProcessId.argtypes = [wt.HWND, ctypes.POINTER(wt.DWORD)]
_u32.GetWindowThreadProcessId.restype = wt.DWORD
_k32.GlobalLock.argtypes = [wt.HANDLE]
_k32.GlobalLock.restype = ctypes.c_void_p
_k32.GlobalUnlock.argtypes = [wt.HANDLE]
_k32.GlobalSize.argtypes = [wt.HANDLE]
_k32.GlobalSize.restype = ctypes.c_size_t
_k32.OpenProcess.argtypes = [wt.DWORD, wt.BOOL, wt.DWORD]
_k32.OpenProcess.restype = wt.HANDLE
_k32.CloseHandle.argtypes = [wt.HANDLE]
_k32.QueryFullProcessImageNameW.argtypes = [wt.HANDLE, wt.DWORD, wt.LPWSTR, ctypes.POINTER(wt.DWORD)]
_k32.QueryFullProcessImageNameW.restype = wt.BOOL
_shell32.DragQueryFileW.argtypes = [wt.HANDLE, wt.UINT, wt.LPWSTR, wt.UINT]
_shell32.DragQueryFileW.restype = wt.UINT

CF_DIB, CF_UNICODETEXT, CF_HDROP = 8, 13, 15
CF_PNG = _u32.RegisterClipboardFormatW("PNG")
CF_HTML = _u32.RegisterClipboardFormatW("HTML Format")

_SOURCE_URL_RES = (re.compile(r"<!--source-url:([^>]*?)-->"),      # Copy Source URL Injector userscript
                   re.compile(r"^SourceURL:(\S+)", re.M))           # browsers' own CF_HTML header


def clipboard_seq() -> int:
    """Windows bumps this number on every clipboard change; reading it is nearly free."""
    return int(_u32.GetClipboardSequenceNumber())


def _global_bytes(handle):
    ptr = _k32.GlobalLock(handle)
    if not ptr:
        return None
    try:
        return ctypes.string_at(ptr, _k32.GlobalSize(handle))
    finally:
        _k32.GlobalUnlock(handle)


def _format_bytes(fmt):
    if not fmt or not _u32.IsClipboardFormatAvailable(fmt):
        return None
    handle = _u32.GetClipboardData(fmt)
    return _global_bytes(handle) if handle else None


def _window_title(hwnd) -> str:
    if not hwnd:
        return ""
    buf = ctypes.create_unicode_buffer(512)
    _u32.GetWindowTextW(hwnd, buf, 512)
    return buf.value


def _window_exe(hwnd) -> str:
    if not hwnd:
        return ""
    pid = wt.DWORD(0)
    _u32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    if not pid.value:
        return ""
    proc = _k32.OpenProcess(0x1000, False, pid.value)  # PROCESS_QUERY_LIMITED_INFORMATION
    if not proc:
        return ""
    try:
        buf = ctypes.create_unicode_buffer(1024)
        size = wt.DWORD(1024)
        if _k32.QueryFullProcessImageNameW(proc, 0, buf, ctypes.byref(size)):
            return os.path.basename(buf.value)
        return ""
    finally:
        _k32.CloseHandle(proc)


def clipboard_source() -> dict:
    """Which app the copy came from.

    The clipboard owner is the app that really put the data there. Clipboard managers re-own the
    clipboard after a copy, so for those (and when there is no owner) the window in front is used.
    """
    fg = _u32.GetForegroundWindow()
    owner = _u32.GetClipboardOwner()
    fg_app, owner_app = _window_exe(fg), _window_exe(owner)
    if owner_app and owner_app.lower() not in CLIPBOARD_MANAGERS:
        app = owner_app
        title = _window_title(fg) if fg_app.lower() == owner_app.lower() else _window_title(owner)
    else:
        app, title = fg_app, _window_title(fg)
    return {"source_app": app, "source_title": title, "owner_app": owner_app}


def source_url_from_html(html: bytes) -> str:
    """Page url from the raw "HTML Format" clipboard block (userscript comment first, then the browser header)."""
    if not html:
        return ""
    text = html[:200000].decode("utf-8", errors="replace")
    for rx in _SOURCE_URL_RES:
        m = rx.search(text)
        if m and m.group(1).strip() and not m.group(1).startswith("about:"):
            return m.group(1).strip()
    return ""


def _dib_to_png(dib: bytes):
    if Image is None:
        return None
    try:
        im = BmpImagePlugin.DibImageFile(io.BytesIO(dib))
        im.load()
        if im.mode == "RGBA" and im.getchannel("A").getextrema() == (0, 0):
            im = im.convert("RGB")  # 32-bit bitmaps with an unused (all zero) alpha byte
        out = io.BytesIO()
        im.save(out, "PNG")
        return out.getvalue()
    except Exception:
        return None


def read_clipboard(allow_files: bool = True):
    """Read the Windows clipboard once.

    Returns None when the clipboard is busy (another app holds it), otherwise
    {"kind": "text"|"image"|"none", "text", "data", "ext", "source_url", "source_file"}.
    """
    for _ in range(15):
        if _u32.OpenClipboard(None):
            break
        time.sleep(0.03)
    else:
        return None
    raw_text = png = dib = html = None
    files = []
    try:
        raw_text = _format_bytes(CF_UNICODETEXT)
        html = _format_bytes(CF_HTML)
        png = _format_bytes(CF_PNG)
        if png is None:
            dib = _format_bytes(CF_DIB)
        if _u32.IsClipboardFormatAvailable(CF_HDROP):
            hdrop = _u32.GetClipboardData(CF_HDROP)
            if hdrop:
                count = _shell32.DragQueryFileW(hdrop, 0xFFFFFFFF, None, 0)
                buf = ctypes.create_unicode_buffer(1024)
                for i in range(min(count, 4)):
                    if _shell32.DragQueryFileW(hdrop, i, buf, 1024):
                        files.append(buf.value)
                if count > len(files):
                    files.append("")  # more files than we looked at: never a single-image copy
    finally:
        _u32.CloseClipboard()

    out = {"kind": "none", "text": "", "data": None, "ext": "", "source_url": "", "source_file": "",
           "files": files}    # files = a file copy (Explorer / DOpus); "" in it = more files than were read
    out["source_url"] = source_url_from_html(html)
    text = ""
    if raw_text:
        text = raw_text.decode("utf-16-le", errors="replace").split("\x00", 1)[0]
    if text.strip():
        out["kind"], out["text"] = "text", text[:MAX_TEXT_CHARS]
        return out
    if png and len(png) <= MAX_IMAGE_BYTES:
        out["kind"], out["data"], out["ext"] = "image", png, ".png"
        return out
    if dib:
        converted = _dib_to_png(dib)
        if converted and len(converted) <= MAX_IMAGE_BYTES:
            out["kind"], out["data"], out["ext"] = "image", converted, ".png"
            return out
    if (allow_files and len(files) == 1 and files[0].lower().endswith(IMAGE_EXTS)
            and not exclude_reason({"kind": "none", "files": files})):   # an excluded file is not even read
        try:
            if os.path.getsize(files[0]) <= MAX_IMAGE_BYTES:
                with open(files[0], "rb") as fh:
                    out["data"] = fh.read()
                out["kind"], out["source_file"] = "image", files[0]
                out["ext"] = os.path.splitext(files[0])[1].lower()
        except OSError:
            pass
    return out


# ---------------------------------------------------------------- clip store (files + sqlite)

_db_lock = threading.Lock()
_db_ready = False

_SCHEMA = """
CREATE TABLE IF NOT EXISTS clips (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    ts           TEXT NOT NULL,      -- local time, YYYY-MM-DD HH:MM:SS
    ts_unix      REAL NOT NULL,
    direction    TEXT NOT NULL,      -- ios_to_pc | pc_to_ios
    kind         TEXT NOT NULL,      -- text | image
    text         TEXT,
    file         TEXT,               -- path relative to the store dir
    bytes        INTEGER,
    sha256       TEXT,
    source_app   TEXT,               -- exe of the window that was in front when the copy happened
    source_title TEXT,               -- that window's title (page title for browsers)
    source_url   TEXT,               -- page url when the browser put one on the clipboard
    owner_app    TEXT,               -- exe that owns the clipboard data
    source_file  TEXT,               -- original path when an image file was copied
    device       TEXT
);
CREATE INDEX IF NOT EXISTS clips_ts ON clips (ts_unix);
-- CopyQ items deleted from the phone are copied here first, so a delete can always be undone by hand.
CREATE TABLE IF NOT EXISTS copyq_deleted (
    id   INTEGER PRIMARY KEY AUTOINCREMENT,
    ts   TEXT NOT NULL,
    tab  TEXT NOT NULL,
    text TEXT,
    note TEXT,
    tags TEXT
);
"""
# Columns added after the first version: name = user given name, deleted_at = hidden from the phone
# (the row and its file stay), ios_types = the clipboard data types the phone saw,
# ai_tab / ai_reason = where clippip_ai.py filed the clip (shown as "ai ..." tabs in the app).
_EXTRA_COLUMNS = ("name", "deleted_at", "ios_types", "ai_tab", "ai_reason")


def _connect():
    global _db_ready
    os.makedirs(STORE_DIR, exist_ok=True)
    con = sqlite3.connect(DB_PATH, timeout=10)
    if not _db_ready:
        con.executescript(_SCHEMA)
        have = {row[1] for row in con.execute("PRAGMA table_info(clips)")}
        for col in _EXTRA_COLUMNS:
            if col not in have:
                con.execute(f"ALTER TABLE clips ADD COLUMN {col} TEXT")
        con.commit()
        _db_ready = True
    return con


# iOS bundle id -> the name shown on the phone, for when only the id is known.
IOS_BUNDLES = {
    "com.reddit.reddit": "Reddit", "com.brave.ios.browser": "Brave", "com.apple.mobilesafari": "Safari",
    "com.google.chrome.ios": "Chrome", "org.mozilla.ios.firefox": "Firefox", "com.apple.mobilenotes": "Notes",
    "com.apple.shortcuts": "Shortcuts", "com.apple.reminders": "Reminders", "com.apple.mobileslideshow": "Photos",
    "com.hammerandchisel.discord": "Discord", "ph.telegra.telegraph": "Telegram", "md.obsidian": "Obsidian",
    "com.anthropic.claude": "Claude", "com.openai.chat": "ChatGPT", "com.google.ios.youtube": "YouTube",
    "com.atebits.tweetie2": "X", "com.apple.mobilemail": "Mail", "com.apple.mobilesms": "Messages",
}
_REDDIT_HOST_RE = re.compile(r"(^|\.)(reddit\.com|redd\.it|redditmedia\.com)$")
_REDDIT_SHARE_RE = re.compile(r"^/(r|u|user)/[^/]+/s/[A-Za-z0-9]+/?$")   # the Reddit app's "Share > Copy link"
# One clause for the "from reddit" tab: copied in the Reddit app, or from a reddit page in a browser.
_REDDIT_SQL = ("(lower(coalesce(source_app,'')) = 'reddit'"
               " OR lower(coalesce(source_title,'')) LIKE '%reddit.com' OR lower(coalesce(source_title,'')) LIKE '%redd.it'"
               " OR lower(coalesce(source_url,'')) LIKE '%reddit.com/%' OR lower(coalesce(source_url,'')) LIKE '%redd.it/%')")
MAX_APP_TABS = 10


def _clean_label(value: str, limit: int = 80) -> str:
    return re.sub(r"[\x00-\x1f\x7f]+", " ", value or "").strip()[:limit]


def ios_source(types: str, url: str, hosts: str = "", origin: str = "", origin_name: str = "", app: str = "") -> dict:
    """Where a phone copy came from. The best source wins:
    origin / origin_name = what iOS itself says copied it (bundle id / app name), when the phone can read that,
    app = the app the phone's Shortcuts automations said was open,
    otherwise a guess from the clipboard data types and the copied url.
    hosts = comma separated sites found inside a copied web page fragment (used when there is no url)."""
    from urllib.parse import urlparse
    low = (types or "").lower()
    site = path = ""
    if url:
        try:
            parsed = urlparse(url)
            site, path = (parsed.hostname or parsed.netloc or "").lower(), parsed.path or ""
        except ValueError:  # a copied string that only looks like a url
            pass
    if not site:
        found = [h.strip().lower() for h in (hosts or "").split(",") if h.strip()]
        site = next((h for h in found if _REDDIT_HOST_RE.search(h)), found[0] if found else "")
    site = _clean_label(site)

    guess = ""
    if "webarchive" in low or "web archive" in low:
        guess = "iOS browser"
    elif "com.apple.notes" in low or "mobilenotes" in low:
        guess = "Notes"
    elif "link.contentkit" in low:
        guess = "Shortcuts"
    elif "com.apple.reminders" in low:
        guess = "Reminders"
    elif "webkit.custom-pasteboard-data" in low or ("public.html" in low and "flat-rtfd" in low):
        guess = "web view"            # a browser, or an app showing a web page
    elif _REDDIT_HOST_RE.search(site) and _REDDIT_SHARE_RE.match(path):
        guess = "Reddit"
    elif url:
        guess = "iOS link"

    origin = _clean_label(origin, 120)
    named = _clean_label(origin_name) or IOS_BUNDLES.get(origin.lower(), "") or origin
    return {"source_app": named or _clean_label(app) or guess, "source_title": site}


def content_sha(kind: str, text: str = "", data: bytes = None) -> str:
    if kind == "text":
        norm = text.replace("\r\n", "\n").replace("\r", "\n").strip("\n\x00 \t")
        return hashlib.sha256(norm.encode("utf-8", errors="replace")).hexdigest()
    return hashlib.sha256(data or b"").hexdigest()


def _make_thumb(clip_id: int, data: bytes) -> None:
    if Image is None:
        return
    try:
        with Image.open(io.BytesIO(data)) as im:
            im = im.convert("RGB")
            im.thumbnail((360, 360))
            os.makedirs(os.path.join(STORE_DIR, "thumbs"), exist_ok=True)
            im.save(os.path.join(STORE_DIR, "thumbs", f"{clip_id}.jpg"), "JPEG", quality=80)
    except Exception:
        pass


def save_clip(direction: str, kind: str, text: str = "", data: bytes = None, ext: str = "",
              source_app: str = "", source_title: str = "", source_url: str = "", owner_app: str = "",
              source_file: str = "", device: str = "", ios_types: str = "") -> int:
    """Write one clip as a file + a db row. The same content twice in a row is stored once. Returns the row id."""
    sha = content_sha(kind, text, data)
    now = datetime.now()
    with _db_lock, closing(_connect()) as con:
        last = con.execute("SELECT id, sha256 FROM clips ORDER BY id DESC LIMIT 1").fetchone()
        if last and last[1] == sha:
            return int(last[0])
        payload = text.encode("utf-8", errors="replace") if kind == "text" else (data or b"")
        cur = con.execute(
            "INSERT INTO clips (ts, ts_unix, direction, kind, text, bytes, sha256, source_app, source_title,"
            " source_url, owner_app, source_file, device, ios_types) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (now.strftime("%Y-%m-%d %H:%M:%S"), now.timestamp(), direction, kind,
             text if kind == "text" else None, len(payload), sha, source_app, source_title, source_url,
             owner_app, source_file, device, ios_types))
        clip_id = int(cur.lastrowid)
        side = "ios" if direction == "ios_to_pc" else "pc"
        if kind == "text":
            ext = ".txt"
        elif ext not in IMAGE_EXTS:
            ext = ".png"
        rel = os.path.join("clips", side, now.strftime("%Y-%m"),
                           f"{now.strftime('%Y%m%d_%H%M%S')}_{clip_id:06d}_{side}{ext}")
        full = os.path.join(STORE_DIR, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "wb") as fh:  # bytes: text is stored exactly as copied, nothing appended
            fh.write(payload)
        con.execute("UPDATE clips SET file = ? WHERE id = ?", (rel, clip_id))
        con.commit()
    if kind == "image":
        _make_thumb(clip_id, payload)
    return clip_id


def clip_file(clip_id: int, thumb: bool = False):
    """-> (absolute path, content type) or None."""
    with _db_lock, closing(_connect()) as con:
        row = con.execute("SELECT file, kind FROM clips WHERE id = ?", (clip_id,)).fetchone()
    if not row or not row[0]:
        return None
    if thumb and row[1] == "image":
        tpath = os.path.join(STORE_DIR, "thumbs", f"{clip_id}.jpg")
        if os.path.isfile(tpath):
            return tpath, "image/jpeg"
    full = os.path.join(STORE_DIR, row[0])
    if not os.path.isfile(full):
        return None
    ext = os.path.splitext(full)[1].lower()
    ctype = {".txt": "text/plain; charset=utf-8", ".png": "image/png", ".jpg": "image/jpeg",
             ".jpeg": "image/jpeg", ".webp": "image/webp", ".gif": "image/gif", ".bmp": "image/bmp"}.get(ext)
    return full, ctype or "application/octet-stream"


def _terms(query: str):
    return [t for t in (query or "").lower().split() if t]


_SEARCH_COLS = ("text", "name", "source_app", "source_title", "source_url")


def _like_escape(term: str) -> str:
    return term.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


_DATE_FULL = re.compile(r"^(\d{4})-(\d{1,2})(?:-(\d{1,2}))?$")
_DATE_SHORT = re.compile(r"^(\d{1,2})[-/](\d{1,2})$")


def _date_term(term: str) -> str:
    """A search word that means a day or month -> a LIKE pattern on ts ("YYYY-MM-DD HH:MM:SS"), else ''."""
    from datetime import timedelta
    if term in ("today", "yesterday"):
        d = datetime.now() - timedelta(days=1 if term == "yesterday" else 0)
        return d.strftime("%Y-%m-%d") + "%"
    m = _DATE_FULL.match(term)
    if m and 1 <= int(m.group(2)) <= 12:
        if m.group(3):
            return f"{m.group(1)}-{int(m.group(2)):02d}-{int(m.group(3)):02d}%"
        return f"{m.group(1)}-{int(m.group(2)):02d}-%"
    m = _DATE_SHORT.match(term)
    if m and 1 <= int(m.group(1)) <= 12 and 1 <= int(m.group(2)) <= 31:
        return f"%-{int(m.group(1)):02d}-{int(m.group(2)):02d} %"
    return ""


def history_items(query: str = "", offset: int = 0, limit: int = 100, kind: str = "", side: str = "") -> dict:
    """Newest first; every search word must appear in the text, name, source app, title or url.

    side = "ios" (copied on the phone) or "pc" (copied on the laptop), empty = both,
    or "ai:<tab>" = the clips clippip_ai.py filed under that tab,
    or "app:<name>" = phone clips copied in that app ("app:reddit" also takes reddit pages in a browser).
    """
    where, args = ["deleted_at IS NULL"], []
    if side.startswith("ai:"):
        where.append("ai_tab = ?")
        args.append(side[3:])
    elif side.startswith("app:"):
        where.append("direction = 'ios_to_pc'")
        if side[4:].lower() == "reddit":
            where.append(_REDDIT_SQL)
        else:
            where.append("lower(coalesce(source_app,'')) = ?")
            args.append(side[4:].lower())
    elif side in ("ios", "pc"):
        where.append("direction = ?")
        args.append("ios_to_pc" if side == "ios" else "pc_to_ios")
    if kind:
        where.append("kind = ?")
        args.append(kind)
    for term in _terms(query):
        day = _date_term(term)
        if day:                                   # today / yesterday / 2026-10-15 / 2026-10 / 10-15 / 10/15
            where.append("ts LIKE ?")
            args.append(day)
            continue
        if term.startswith("app:") and len(term) > 4:   # app:chrome = only clips copied in that app
            where.append("lower(coalesce(source_app,'')) LIKE ? ESCAPE '\\'")
            args.append("%" + _like_escape(term[4:]) + "%")
            continue
        like = "%" + _like_escape(term) + "%"
        where.append("(" + " OR ".join(f"lower(coalesce({c},'')) LIKE ? ESCAPE '\\'" for c in _SEARCH_COLS) + ")")
        args += [like] * len(_SEARCH_COLS)
    clause = " WHERE " + " AND ".join(where)
    with _db_lock, closing(_connect()) as con:
        total = con.execute("SELECT count(*) FROM clips" + clause, args).fetchone()[0]
        rows = con.execute(
            "SELECT id, ts, direction, kind, text, bytes, source_app, source_title, source_url, name FROM clips"
            + clause + " ORDER BY id DESC LIMIT ? OFFSET ?", args + [limit, offset]).fetchall()
    items = []
    for cid, ts, direction, kind_, text, size, app, title, url, name in rows:
        src = " | ".join(x for x in ("iPhone" if direction == "ios_to_pc" else "", app, title) if x)
        item = {"key": f"h{cid}", "kind": kind_, "text": text or f"[image {int((size or 0) / 1024)} KB]",
                "name": name or "", "note": f"{ts}  {src}".strip(), "tags": [], "url": url or "", "sig": "",
                "src": (app or "") if direction == "pc_to_ios" else ""}
        if kind_ == "image":
            item["img"] = f"/clip/file?id={cid}"
            item["thumb"] = f"/clip/thumb?id={cid}"
        items.append(item)
    return {"total": total, "items": items}


def _history_update(clip_id: int, column: str, value) -> None:
    with _db_lock, closing(_connect()) as con:
        cur = con.execute(f"UPDATE clips SET {column} = ? WHERE id = ? AND deleted_at IS NULL", (value, clip_id))
        con.commit()
        if cur.rowcount != 1:
            raise KeyError(clip_id)


# ---------------------------------------------------------------- CopyQ tabs

# One copyq call per tab: texts, notes and tags come back as three arrays, image rows as a fourth.
_COPYQ_FETCH = r"""
var sel = ItemSelection(%s).selectAll();
function strs(mime) {
  var a = sel.itemsFormat(mime), out = [];
  for (var i = 0; i < a.length; i++) out.push(a[i] === undefined || a[i] === null ? '' : str(a[i]).slice(0, %d));
  return out;
}
var img = ItemSelection(%s).select(/^/, 'image/png').rows();
print(JSON.stringify({t: strs(mimeText), n: strs(mimeItemNotes), g: strs('application/x-copyq-tags'), i: img}));
"""

_copyq_cache = {}        # tab name -> {"at": time, "items": [...]}; bounded by the tab list in the config
_copyq_lock = threading.Lock()
_copyq_refreshing = set()


def _copyq_run(args, timeout=90):
    return subprocess.run([COPYQ_EXE] + args, capture_output=True, timeout=timeout,
                          creationflags=subprocess.CREATE_NO_WINDOW)


def _copyq_fetch(tab: str) -> list:
    name = json.dumps(tab)
    res = _copyq_run(["eval", "--", _COPYQ_FETCH % (name, MAX_TEXT_CHARS, name)])
    if res.returncode != 0:
        raise RuntimeError(res.stderr.decode("utf-8", errors="replace").strip() or "copyq failed")
    raw = json.loads(res.stdout.decode("utf-8", errors="replace"))
    images = set(raw.get("i") or [])
    items = []
    for row, text in enumerate(raw["t"]):
        text = text.replace("\x00", "")
        note = raw["n"][row].replace("\x00", "") if row < len(raw["n"]) else ""
        tags = raw["g"][row].replace("\x00", "") if row < len(raw["g"]) else ""
        is_img = row in images and not text.strip()
        if not text.strip() and not is_img and not note.strip():
            continue              # nothing showable (e.g. drag data only)
        # t / n are the item's real text and notes in CopyQ (used to re-find it before an edit);
        # "name" is what the phone shows as the clip's name = the CopyQ notes.
        shown = "[image]" if is_img else (text if text.strip() else note)
        items.append({"row": row, "kind": "image" if is_img else "text", "t": text, "n": note,
                      "text": shown, "name": note if text.strip() or is_img else "",
                      "tags": [x.strip() for x in tags.split(",") if x.strip()],
                      "sig": _sig(text, note)})
    return items


def _sig(text: str, note: str) -> str:
    return hashlib.sha1((text + "\x00" + note).encode("utf-8", errors="replace")).hexdigest()[:16]


def _copyq_refresh(tab: str) -> None:
    try:
        items = _copyq_fetch(tab)
        with _copyq_lock:
            _copyq_cache[tab] = {"at": time.time(), "items": items}
    except Exception as exc:
        print(f"[copyq] refresh of {tab!r} failed: {exc}")
    finally:
        with _copyq_lock:
            _copyq_refreshing.discard(tab)


def _copyq_tab_items(tab: str, force: bool = False) -> list:
    """Cached items of one tab. First use loads it, later uses return the cache and refresh it in the background."""
    with _copyq_lock:
        entry = _copyq_cache.get(tab)
        stale = entry is None or force or time.time() - entry["at"] > COPYQ_TTL
        start = stale and tab not in _copyq_refreshing
        if start:
            _copyq_refreshing.add(tab)
    if start:
        if entry is None or force:
            _copyq_refresh(tab)
        else:
            threading.Thread(target=_copyq_refresh, args=(tab,), daemon=True).start()
    elif entry is None:
        deadline = time.time() + 60      # another request is loading this tab right now
        while time.time() < deadline:
            time.sleep(0.2)
            with _copyq_lock:
                if tab in _copyq_cache or tab not in _copyq_refreshing:
                    break
    with _copyq_lock:
        entry = _copyq_cache.get(tab)
    if entry is None:
        raise RuntimeError("could not read the CopyQ tab (is CopyQ running?)")
    return entry["items"]


# ---------------------------------------------------------------- Ditto groups

# Read-only browser for the Ditto clipboard manager's groups. The DB is ~155 GB and always open in
# Ditto, so it is opened with mode=ro, one indexed query per group, and the result is cached like CopyQ.
# Nothing here ever writes to Ditto.

DITTO_TTL = 300          # seconds a cached Ditto group is served before a background refresh
_ditto_cache = {}        # group id -> {"at": time, "items": [...]}
_ditto_lock = threading.Lock()
_ditto_refreshing = set()
_ditto_path = {"at": 0.0, "path": ""}

# The ORDER BY is Ditto's own group order, copied from the Ditto source (src/MainFrm.cpp and the
# Main_InGroup2 index): stickyClipGroupOrder DESC (pinned clips first, -2147483647 = not pinned),
# then clipGroupOrder DESC.
_DITTO_SQL = """
SELECT m.lID, m.mText, m.QuickPasteText, d.ooData
FROM Main m LEFT JOIN Data d ON d.lParentID = m.lID AND d.strClipBoardFormat = 'CF_UNICODETEXT'
WHERE m.bIsGroup = 0 AND m.lParentID = ?
ORDER BY m.stickyClipGroupOrder DESC, m.clipGroupOrder DESC
"""


def ditto_groups() -> list:
    out = []
    for g in load_config().get("ditto_groups", []):
        try:
            out.append({"id": int(g["id"]), "label": str(g.get("label") or g["id"]),
                        "parent": int(g["parent"]) if g.get("parent") else None})
        except (KeyError, TypeError, ValueError):
            continue
    return out


def _ditto_db() -> str:
    """Ditto's live DB path from the registry (it changes with the Ditto version), re-read hourly."""
    if _ditto_path["path"] and time.time() - _ditto_path["at"] < 3600:
        return _ditto_path["path"]
    import winreg
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Ditto") as key:
        path = winreg.QueryValueEx(key, "DBPath3")[0]
    _ditto_path["at"], _ditto_path["path"] = time.time(), path
    return path


def _ditto_text(blob) -> str:
    if not blob:
        return ""
    return bytes(blob).decode("utf-16-le", errors="replace").rstrip("\x00")


def _ditto_fetch(gid: int) -> list:
    from urllib.parse import quote
    uri = "file:///" + quote(_ditto_db().replace("\\", "/")) + "?mode=ro"
    items = []
    with closing(sqlite3.connect(uri, uri=True, timeout=10)) as con:
        for lid, mtext, quick, blob in con.execute(_DITTO_SQL, (int(gid),)):
            text = _ditto_text(blob)[:MAX_TEXT_CHARS].replace("\x00", "")
            name = (mtext or "").replace("\x00", "").strip()
            if not text.strip():
                if not name:
                    continue                 # image clip (CF_DIB) or empty: not shown
                text = name                  # Ditto shows mText when there is no text payload
            flat = " ".join(text.split())
            if flat.startswith(" ".join(name.split())[:120]) and len(name) >= 8:
                name = ""                    # mText is just the clip text (Ditto's default), not a real name
            tags = [t.strip() for t in (quick or "").replace(";", ",").split(",") if t.strip()]
            items.append({"row": int(lid), "kind": "text", "t": text, "n": name, "text": text,
                          "name": name[:500], "tags": tags, "sig": _sig(text, name)})
    return items


def _ditto_refresh(gid: int) -> None:
    try:
        items = _ditto_fetch(gid)
        with _ditto_lock:
            _ditto_cache[gid] = {"at": time.time(), "items": items}
    except Exception as exc:
        print(f"[ditto] refresh of group {gid} failed: {exc}")
    finally:
        with _ditto_lock:
            _ditto_refreshing.discard(gid)


def _ditto_group_items(gid: int, force: bool = False) -> list:
    """Cached clips of one Ditto group; same load-then-refresh-in-the-background shape as CopyQ."""
    with _ditto_lock:
        entry = _ditto_cache.get(gid)
        stale = entry is None or force or time.time() - entry["at"] > DITTO_TTL
        start = stale and gid not in _ditto_refreshing
        if start:
            _ditto_refreshing.add(gid)
    if start:
        if entry is None or force:
            _ditto_refresh(gid)
        else:
            threading.Thread(target=_ditto_refresh, args=(gid,), daemon=True).start()
    elif entry is None:
        deadline = time.time() + 60      # another request is loading this group right now
        while time.time() < deadline:
            time.sleep(0.2)
            with _ditto_lock:
                if gid in _ditto_cache or gid not in _ditto_refreshing:
                    break
    with _ditto_lock:
        entry = _ditto_cache.get(gid)
    if entry is None:
        raise RuntimeError("could not read the Ditto database")
    return entry["items"]


def _ditto_tab_id(gid) -> str:
    return "ditto:%d" % int(gid)


def _ditto_gid(tab: str):
    """The group id behind a "ditto:<id>" tab, or None when this is not a Ditto tab."""
    if not tab.startswith("ditto:"):
        return None
    try:
        gid = int(tab.split(":", 1)[1])
    except ValueError:
        raise KeyError(tab)
    if gid not in {g["id"] for g in ditto_groups()}:
        raise KeyError(tab)
    return gid


CHUNKS_JSON = os.path.join(os.path.expanduser("~"), "Documents local backup of HDD", "00000 ditto clips database",
                           "Prompt clips database", "nai_prompt_chunks.json")
CHUNK_TAB = "chunks"


def _chunk_groups() -> list:
    """NAI prompt chunk groups from the chunk server's export (read only, re-read when the file changes)."""
    try:
        mtime = os.path.getmtime(CHUNKS_JSON)
        if _chunk_cache.get("m") != mtime:
            with open(CHUNKS_JSON, encoding="utf-8") as fh:
                _chunk_cache.update(m=mtime, groups=json.load(fh))
        return _chunk_cache["groups"]
    except (OSError, ValueError):
        return []


_chunk_cache: dict = {}


def _chunk_items(tab: str, query: str, offset: int, limit: int) -> dict:
    terms = _terms(query)
    want = tab.partition(":")[2]
    matched = []
    for g in _chunk_groups():
        if want and g.get("label") != want:
            continue
        for i, c in enumerate(g.get("chunks", [])):
            text = c.get("expansion", "")
            hay = (text + " " + c.get("label", "")).lower()
            if terms and not all(t in hay for t in terms):
                continue
            matched.append((g.get("label", ""), i, c))
    items = [{"key": f"k{grp}#{i}", "kind": "text", "text": c.get("expansion", ""), "name": c.get("label", ""),
              "note": grp if not want else "", "tags": [], "url": "",
              "sig": hashlib.md5(c.get("expansion", "").encode("utf-8")).hexdigest()[:12]}
             for grp, i, c in matched[offset:offset + limit]]
    return {"total": len(matched), "items": items}


def lib_tabs() -> list:
    tabs = [{"id": HISTORY_TAB + ":ios", "label": "phone clips"}, {"id": HISTORY_TAB + ":pc", "label": "pc clips"},
            {"id": HISTORY_TAB, "label": "all clips"}, {"id": "*", "label": "all copyq"}]
    for t in load_config()["copyq_tabs"]:
        entry = {"id": t["tab"], "label": t.get("label") or t["tab"]}
        if t.get("parent"):
            entry["parent"] = t["parent"]
        tabs.append(entry)
    groups = _chunk_groups()
    if groups:
        tabs.append({"id": CHUNK_TAB, "label": "chunks"})
        for g in groups:
            tabs.append({"id": CHUNK_TAB + ":" + g.get("label", ""), "label": "chunk " + g.get("label", ""), "parent": CHUNK_TAB})
    for g in ditto_groups():
        entry = {"id": _ditto_tab_id(g["id"]), "label": g["label"]}
        if g["parent"]:
            entry["parent"] = _ditto_tab_id(g["parent"])
        tabs.append(entry)
    try:  # one tab per AI category that has clips; trash review always comes last
        with _db_lock, closing(_connect()) as con:
            ai = [r[0] for r in con.execute(
                "SELECT ai_tab FROM clips WHERE ai_tab IS NOT NULL AND ai_tab != '' AND deleted_at IS NULL "
                "GROUP BY ai_tab ORDER BY (ai_tab = 'trash review'), ai_tab")]
            # one tab per app phone clips were copied in, most used first; reddit first when it has clips
            apps = [r[0] for r in con.execute(
                "SELECT lower(source_app) FROM clips WHERE direction = 'ios_to_pc' AND deleted_at IS NULL "
                "AND coalesce(source_app,'') != '' AND lower(source_app) != 'reddit' "
                "GROUP BY lower(source_app) ORDER BY count(*) DESC, lower(source_app) LIMIT ?", (MAX_APP_TABS,))]
            if con.execute("SELECT 1 FROM clips WHERE direction = 'ios_to_pc' AND deleted_at IS NULL AND "
                           + _REDDIT_SQL + " LIMIT 1").fetchone():
                apps.insert(0, "reddit")
    except sqlite3.Error:
        ai, apps = [], []
    tabs += [{"id": HISTORY_TAB + ":app:" + name, "label": "from " + name} for name in apps]
    tabs += [{"id": HISTORY_TAB + ":ai:" + name, "label": "ai " + name} for name in ai]
    return tabs


def _tab_names(tab: str) -> list:
    if tab.startswith("ditto:"):
        raise KeyError(tab)                 # Ditto groups are read through _ditto_group_items
    allowed = [t["tab"] for t in load_config()["copyq_tabs"]]
    if tab == "*":
        return allowed
    if tab not in allowed:
        raise KeyError(tab)
    return [tab]


def lib_items(tab: str, query: str = "", offset: int = 0, limit: int = 100, force: bool = False,
              tag: str = "", kind: str = "") -> dict:
    """Search words match the text, the name (CopyQ notes) and the tags; `tag` keeps only clips with that tag."""
    limit = max(1, min(int(limit), 200))
    offset = max(0, int(offset))
    if tab == HISTORY_TAB or tab.startswith(HISTORY_TAB + ":"):
        return history_items(query, offset, limit, kind, side=tab.partition(":")[2])
    if tab == CHUNK_TAB or tab.startswith(CHUNK_TAB + ":"):
        return _chunk_items(tab, query, offset, limit)
    gid = _ditto_gid(tab)
    if gid is not None:
        return _ditto_items(gid, query, offset, limit, force, tag, kind)
    labels = {t["tab"]: t.get("label") or t["tab"] for t in load_config()["copyq_tabs"]}
    terms = _terms(query)
    tag = tag.strip().lower()
    matched = []
    for name in _tab_names(tab):
        for it in _copyq_tab_items(name, force):
            if kind and it["kind"] != kind:
                continue
            if tag and tag not in [x.lower() for x in it["tags"]]:
                continue
            if terms:
                hay = (it["text"] + "\n" + it["name"] + "\n" + ",".join(it["tags"])).lower()
                if not all(term in hay for term in terms):
                    continue
            matched.append((name, it))
    items = []
    for name, it in matched[offset:offset + limit]:
        item = {"key": f"c{name}#{it['row']}", "kind": it["kind"], "text": it["text"], "name": it["name"],
                "note": labels.get(name, name) if tab == "*" else "", "tags": it["tags"], "url": "",
                "sig": it["sig"]}
        if it["kind"] == "image":
            item["img"] = item["thumb"] = "/copyq/img?" + _qs(tab=name, row=it["row"])
        items.append(item)
    return {"total": len(matched), "items": items}


def _ditto_items(gid: int, query: str, offset: int, limit: int, force: bool, tag: str, kind: str) -> dict:
    """Same search as the CopyQ tabs, over one Ditto group (text clips only, read only)."""
    terms = _terms(query)
    tag = tag.strip().lower()
    matched = []
    for it in _ditto_group_items(gid, force):
        if kind and it["kind"] != kind:
            continue
        if tag and tag not in [x.lower() for x in it["tags"]]:
            continue
        if terms:
            hay = (it["text"] + "\n" + it["name"] + "\n" + ",".join(it["tags"])).lower()
            if not all(term in hay for term in terms):
                continue
        matched.append(it)
    items = [{"key": f"d{gid}#{it['row']}", "kind": "text", "text": it["text"], "name": it["name"],
              "note": "", "tags": it["tags"], "url": "", "sig": it["sig"]}
             for it in matched[offset:offset + limit]]
    return {"total": len(matched), "items": items}


def lib_tags(tab: str) -> list:
    """CopyQ tags used in a tab (or all tabs), most used first."""
    if tab == HISTORY_TAB or tab.startswith(HISTORY_TAB + ":") or tab == CHUNK_TAB or tab.startswith(CHUNK_TAB + ":"):
        return []
    counts, shown = {}, {}
    gid = _ditto_gid(tab)
    if gid is not None:
        for it in _ditto_group_items(gid):
            for t in it["tags"]:
                counts[t.lower()] = counts.get(t.lower(), 0) + 1
                shown.setdefault(t.lower(), t)
        return [{"tag": shown[t], "count": n} for t, n in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))]
    for name in _tab_names(tab):
        for it in _copyq_tab_items(name):
            for t in it["tags"]:
                counts[t.lower()] = counts.get(t.lower(), 0) + 1
                shown.setdefault(t.lower(), t)
    return [{"tag": shown[t], "count": n} for t, n in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))]


# Edits re-check inside CopyQ that the row still holds the same clip, so a stale phone list can
# never rename or delete the wrong one.
_COPYQ_EDIT = r"""
var want = %s;
tab(want.tab);
function clean(mime, row) {
  var v = read(mime, row);
  return (v === undefined || v === null ? '' : str(v)).slice(0, %d).replace(/\0/g, '');
}
if (want.row >= size() || clean(mimeText, want.row) !== want.t || clean(mimeItemNotes, want.row) !== want.n) {
  print('MISMATCH');
} else if (want.op === 'rename') {
  if (want.name === '') { change(want.row, mimeItemNotes, undefined); }
  else { change(want.row, mimeItemNotes, want.name); }
  print('OK');
} else if (want.op === 'delete') {
  var before = size();
  if (want.force) { try { plugins.itempinned.unpin(want.row); } catch (e) {} }
  try { remove(want.row); } catch (e) {}
  print(size() < before ? 'OK' : 'PINNED');
}
"""


class ClipEditError(Exception):
    """Carries a short reason for the phone: 'pinned', 'changed' or 'failed'."""


def _copyq_edit(tab: str, item: dict, op: str, name: str = "", force: bool = False) -> str:
    want = {"tab": tab, "row": item["row"], "t": item["t"], "n": item["n"], "op": op, "name": name, "force": force}
    script = _COPYQ_EDIT % (json.dumps(want), MAX_TEXT_CHARS)
    res = subprocess.run([COPYQ_EXE, "eval", "-"], input=script.encode("utf-8"), capture_output=True,
                         timeout=60, creationflags=subprocess.CREATE_NO_WINDOW)
    out = res.stdout.decode("utf-8", errors="replace").strip()
    if res.returncode != 0:
        raise ClipEditError("failed: " + (res.stderr.decode("utf-8", errors="replace").strip()[:200] or "copyq error"))
    return out


def _copyq_find(tab: str, row: int, sig: str, fresh: bool = False):
    """The cached item for a phone key; if the rows moved, the single item with the same content."""
    for attempt in range(1 if fresh else 2):
        items = _copyq_tab_items(tab, force=fresh or attempt == 1)
        hit = [it for it in items if it["row"] == row and it["sig"] == sig]
        if not hit:
            hit = [it for it in items if it["sig"] == sig]
        if len(hit) == 1:
            return hit[0]
    raise ClipEditError("changed")


def _parse_key(key: str):
    if key.startswith("h"):
        return HISTORY_TAB, int(key[1:])
    if key.startswith("d") and "#" in key:
        gid, clip = key[1:].rsplit("#", 1)
        _ditto_gid("ditto:" + gid)
        return "ditto:" + gid, int(clip)
    if key.startswith("c") and "#" in key:
        tab, row = key[1:].rsplit("#", 1)
        _tab_names(tab)
        return tab, int(row)
    raise KeyError(key)


def _copyq_apply(tab: str, row: int, sig: str, op: str, name: str = "", force: bool = False):
    item = _copyq_find(tab, row, sig)
    out = _copyq_edit(tab, item, op, name, force)
    if out == "MISMATCH":                       # CopyQ changed since the cache was read: look again once
        item = _copyq_find(tab, -1, sig, fresh=True)
        out = _copyq_edit(tab, item, op, name, force)
    if out == "PINNED":
        raise ClipEditError("pinned")
    if out != "OK":
        raise ClipEditError("changed" if out == "MISMATCH" else "failed: " + out[:200])
    return item


def block_source_of(key: str) -> str:
    """Block the app a stored PC clip came from (phone: long press > Block source). Returns the entry added."""
    tab, ident = _parse_key(key)
    if tab != HISTORY_TAB:
        raise KeyError(key)
    with _db_lock, closing(_connect()) as con:
        row = con.execute("SELECT source_app FROM clips WHERE id = ? AND direction = 'pc_to_ios'", (ident,)).fetchone()
    if not row or not (row[0] or "").strip():
        raise KeyError(key)
    set_blocked(add=row[0])
    return row[0].strip().lower()


def lib_content(key: str, sig: str) -> dict:
    """The full content behind a phone key: {"kind": "text", "text"} or {"kind": "image", "data"}."""
    tab, ident = _parse_key(key)
    if tab == HISTORY_TAB:
        with _db_lock, closing(_connect()) as con:
            row = con.execute("SELECT kind, text, file FROM clips WHERE id = ?", (ident,)).fetchone()
        if not row:
            raise KeyError(key)
        if row[0] == "text":
            return {"kind": "text", "text": row[1] or ""}
        with open(os.path.join(STORE_DIR, row[2]), "rb") as fh:
            return {"kind": "image", "data": fh.read()}
    gid = _ditto_gid(tab)
    if gid is not None:
        for it in _ditto_group_items(gid):
            if it["row"] == ident:
                return {"kind": "text", "text": it["t"]}
        raise KeyError(key)
    item = _copyq_find(tab, ident, sig)
    if item["kind"] == "image":
        data = copyq_image(tab, item["row"])
        if not data:
            raise ClipEditError("changed")
        return {"kind": "image", "data": data}
    return {"kind": "text", "text": item["t"] if item["t"].strip() else item["n"]}


def lib_rename(key: str, sig: str, name: str) -> None:
    """History clips get a name column; a CopyQ clip's name is its notes."""
    name = name.strip()[:500]
    tab, ident = _parse_key(key)
    if tab.startswith("ditto:"):
        raise ClipEditError("the Ditto library is read only")
    if tab == HISTORY_TAB:
        _history_update(ident, "name", name)
        return
    _copyq_apply(tab, ident, sig, "rename", name)
    _copyq_tab_items(tab, force=True)


def lib_delete(key: str, sig: str, force: bool = False) -> None:
    """History clips are only hidden (row and file stay). CopyQ clips are copied to copyq_deleted, then removed."""
    tab, ident = _parse_key(key)
    if tab.startswith("ditto:"):
        raise ClipEditError("the Ditto library is read only")
    if tab == HISTORY_TAB:
        _history_update(ident, "deleted_at", datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
        return
    item = _copyq_find(tab, ident, sig)
    with _db_lock, closing(_connect()) as con:
        cur = con.execute("INSERT INTO copyq_deleted (ts, tab, text, note, tags) VALUES (?,?,?,?,?)",
                          (datetime.now().strftime("%Y-%m-%d %H:%M:%S"), tab, item["t"], item["n"],
                           ", ".join(item["tags"])))
        saved = cur.lastrowid
        con.commit()
    try:
        _copyq_apply(tab, ident, sig, "delete", force=force)
    except ClipEditError:
        with _db_lock, closing(_connect()) as con:      # nothing was removed: drop the safety copy again
            con.execute("DELETE FROM copyq_deleted WHERE id = ?", (saved,))
            con.commit()
        raise
    _copyq_tab_items(tab, force=True)


def lib_file(key: str, sig: str, dest: str) -> str:
    """Phone dragged a clip onto a Library tab. -> "moved" or "copied".

    dest "history:ai:<tab>" = file a history clip under that ai tab (moved, nothing else changes);
    dest = a CopyQ tab from the config = add a copy of the clip at the top of that tab (source untouched).
    """
    dest = dest.strip()
    if dest.startswith(HISTORY_TAB + ":ai:"):
        tab, ident = _parse_key(key)
        if tab != HISTORY_TAB:
            raise ClipEditError("only clip history items can go to an ai tab")
        name = dest[len(HISTORY_TAB) + 4:].strip()
        if not name:
            raise ClipEditError("no tab")
        _history_update(ident, "ai_tab", name)
        _history_update(ident, "ai_reason", "moved on phone")
        return "moved"
    if dest not in [t["tab"] for t in load_config()["copyq_tabs"]]:
        raise ClipEditError("can't drop clips on that tab")
    content = lib_content(key, sig)
    if content["kind"] == "text":     # json.dumps escapes non-ascii, so nothing depends on code pages
        args = ["eval", "-"]
        data = ("tab(%s); write(0, mimeText, %s); print('OK');"
                % (json.dumps(dest), json.dumps(content["text"]))).encode("utf-8")
    else:
        args, data = ["tab", dest, "write", "0", "image/png", "-"], content["data"]
    res = subprocess.run([COPYQ_EXE] + args, input=data, capture_output=True, timeout=60,
                         creationflags=subprocess.CREATE_NO_WINDOW)
    if res.returncode != 0:
        raise ClipEditError("failed: " + (res.stderr.decode("utf-8", errors="replace").strip()[:200] or "copyq error"))
    _copyq_tab_items(dest, force=True)
    return "copied"


def _qs(**kw) -> str:
    from urllib.parse import urlencode
    return urlencode(kw)


def copyq_image(tab: str, row: int):
    if tab not in [t["tab"] for t in load_config()["copyq_tabs"]]:
        return None
    res = _copyq_run(["tab", tab, "read", "image/png", str(int(row))], timeout=30)
    return res.stdout if res.returncode == 0 and res.stdout else None
