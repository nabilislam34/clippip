"""Forward links copied on the phone to the local browsing history server.

Any http(s) url that arrives in a ClipPiP clip is POSTed to the local browsing
history project's `/capture` endpoint (`local browsing history\\run_server.py`,
http://127.0.0.1:8770/capture by default), which owns the SQLite database. This
module never touches that database directly.

Resource rules this follows, since the sync server is long lived:
  * ONE worker thread, started on the first forward, not one per clip
  * bounded queue (links are dropped, never queued without limit)
  * bounded dedupe cache, so the same url copied twice is sent once
  * every failure is swallowed and logged: a dead history server must never
    break clipboard sync

Config lives in clippip_config.json under "link_capture":
  {"enabled": true, "endpoint": "...", "timeout": 3.0, "ios_only": true,
   "max_per_clip": 5, "dedupe_minutes": 60}
"""
from __future__ import annotations

import json
import queue
import re
import threading
import time
import urllib.error
import urllib.request
from collections import OrderedDict

import clippip_store as store

DEFAULTS = {
    "enabled": True,
    "endpoint": "http://127.0.0.1:8770/capture",
    "timeout": 3.0,
    "ios_only": True,        # only links copied on the phone, not PC clips
    "max_per_clip": 5,
    "dedupe_minutes": 60,
}

# http(s) urls; the trailing cut keeps sentence punctuation out of the url
_URL_RE = re.compile(r"https?://[^\s<>\"']+", re.I)
_TRAILING = ".,;:!?)]}'\"’”"

_MAX_SCAN = 20_000      # a 56 MB TSV has been on this clipboard before
_QUEUE_MAX = 50
_DEDUPE_MAX = 400

_q: queue.Queue | None = None
_worker: threading.Thread | None = None
_lock = threading.Lock()
_seen: OrderedDict[str, float] = OrderedDict()


def settings() -> dict:
    cfg = dict(DEFAULTS)
    raw = store.load_config().get("link_capture")
    if isinstance(raw, dict):
        cfg.update(raw)
    return cfg


def extract_urls(text: str, limit: int = 5) -> list[str]:
    """Every http(s) url in the clip, in order, deduped, at most `limit`."""
    if not text:
        return []
    out: list[str] = []
    for raw in _URL_RE.findall(text[:_MAX_SCAN]):
        url = raw.rstrip(_TRAILING)
        # a url ending in ")" is usually a markdown link, but "...(x)" can be real
        if url.count("(") > url.count(")"):
            url = raw.rstrip(_TRAILING[:-1]) if raw.endswith(")") else url
        if len(url) < 12 or url in out:
            continue
        out.append(url)
        if len(out) >= limit:
            break
    return out


def _title_for(text: str, url: str) -> str:
    """A shared link is often "Some title\\nhttps://...": use that line as the title."""
    head = text.split(url, 1)[0].strip()
    if not head:
        return ""
    line = head.splitlines()[-1].strip()
    return line[:300] if 3 <= len(line) <= 300 else ""


def _fresh(url: str, minutes: float) -> bool:
    """False if this url was already forwarded recently."""
    cutoff = time.time() - minutes * 60
    with _lock:
        while _seen and next(iter(_seen.values())) < cutoff:
            _seen.popitem(last=False)
        if _seen.get(url, 0) >= cutoff:
            return False
        _seen[url] = time.time()
        _seen.move_to_end(url)
        while len(_seen) > _DEDUPE_MAX:
            _seen.popitem(last=False)
    return True


def _post(payload: dict, endpoint: str, timeout: float) -> str:
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(endpoint, data=body, method="POST",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return f"{resp.status}"


def _run() -> None:
    while True:
        payload, endpoint, timeout = _q.get()
        try:
            status = _post(payload, endpoint, timeout)
            print(f"[link] captured {payload['current_url'][:120]} ({status})")
        except (urllib.error.URLError, OSError, TimeoutError) as exc:
            # the history server being down is normal, not an error worth a traceback
            print(f"[link] capture failed ({type(exc).__name__}): {payload['current_url'][:120]}")
        except Exception as exc:                      # never kill the worker
            print(f"[link] capture error {exc!r}")
        finally:
            _q.task_done()


def _ensure_worker() -> None:
    global _q, _worker
    if _worker is not None and _worker.is_alive():
        return
    with _lock:
        if _worker is not None and _worker.is_alive():
            return
        if _q is None:
            _q = queue.Queue(maxsize=_QUEUE_MAX)
        _worker = threading.Thread(target=_run, name="clippip-links", daemon=True)
        _worker.start()


def forward(text: str, direction: str = "ios_to_pc", source_app: str = "",
            device: str = "") -> list[str]:
    """Queue every link in this clip for capture. Returns the urls queued.

    Fire and forget: this returns immediately and never raises.
    """
    try:
        cfg = settings()
        if not cfg.get("enabled", True):
            return []
        if cfg.get("ios_only", True) and direction != "ios_to_pc":
            return []
        urls = extract_urls(text, int(cfg.get("max_per_clip", 5) or 5))
        if not urls:
            return []
        minutes = float(cfg.get("dedupe_minutes", 60) or 0)
        endpoint = str(cfg.get("endpoint") or DEFAULTS["endpoint"])
        timeout = float(cfg.get("timeout", 3.0) or 3.0)
        _ensure_worker()
        queued = []
        for url in urls:
            if minutes and not _fresh(url, minutes):
                continue
            payload = {
                "current_url": url,
                "canonical_url": url,
                "title": _title_for(text, url),
                "context": "clippip",
                "content_type": "link",
                "source_tags": [t for t in ("clippip", (source_app or "").strip().lower(),
                                            (device or "").strip().lower()) if t],
                "text_excerpt": text.strip()[:2000] if text.strip() != url else "",
            }
            try:
                _q.put_nowait((payload, endpoint, timeout))
            except queue.Full:
                print("[link] queue full, dropped " + url[:120])
                break
            queued.append(url)
        return queued
    except Exception as exc:
        print(f"[link] forward skipped: {exc!r}")
        return []
