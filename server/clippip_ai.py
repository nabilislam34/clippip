"""Local-AI organizer for CopyQ clips (ClipPiP branch local-ai-organizer).

Scans INBOX tabs, decides per clip: junk (one-time copies) or a prompt section / note,
and MOVES it into a separate "ai organized/..." tab tree. The user's own tabs are never
touched as destinations and pinned clips are never moved. Nothing is deleted.

Pipeline per clip (cheapest first):
  1. junk rules   : file paths, logs/tracebacks, bare numbers/hashes     -> trash review
  2. section rules: prompt_sections via clip_section (same rules as the gallery) -> section tab
  3. local LLM    : Ollama (qwen2.5 7b), only for what rules cannot place -> trash review / notes

Dry run is the default (writes a TSV report, moves nothing).
  python clippip_ai.py                       # dry run on the inbox tabs
  python clippip_ai.py --apply               # really move
  python clippip_ai.py --tabs "temp" --limit 50
One-shot process: loads the section rules (~320 MB), then exits. Ollama unloads the model
2 minutes after the last call (keep_alive).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

# pythonw (scheduled task) has no stdout/stderr; imported modules call sys.stdout.reconfigure()
if sys.stdout is None:
    sys.stdout = open(os.devnull, "w", encoding="utf-8")
if sys.stderr is None:
    sys.stderr = open(os.devnull, "w", encoding="utf-8")

HERE = Path(__file__).resolve().parent
GALLERY_BUILD = HERE.parent / "posting automation" / "prompt db" / "gallery_fable_build"
COPYQ_EXE = r"C:\Program Files\CopyQ\copyq.exe"
OLLAMA_URL = "http://127.0.0.1:11434/api/generate"
MODEL = "qwen2.5:7b-instruct-q4_K_M"
# 2026-10-12: the local model is OFF for good (it filled the 6 GB card and crashed the browser).
# Rules and the prompt sectioner do all the sorting; a clip they cannot place is a plain note.
USE_LLM = False
REPORT = HERE / "clippip_ai_report.tsv"          # overwritten each run
CACHE = HERE / "clippip_ai_cache.json"           # sha -> verdict, capped
CACHE_MAX = 5000

INBOX_TABS = ["&clipboard", "temp"]
OUT_ROOT = os.environ.get("CLIPPIP_AI_ROOT", "ai organized")
TRASH = f"{OUT_ROOT}/trash review"
SECTION_TABS = {
    "artist_mix": f"{OUT_ROOT}/artist mixes",
    "artist": f"{OUT_ROOT}/artists",
    "character": f"{OUT_ROOT}/characters",
    "body": f"{OUT_ROOT}/body",
    "face": f"{OUT_ROOT}/faces",
    "sex_acts": f"{OUT_ROOT}/sex acts",
    "clothes": f"{OUT_ROOT}/clothes",
    "text": f"{OUT_ROOT}/text and dialogue",
    "multichar": f"{OUT_ROOT}/multichar",
}
OTHER_PROMPTS = f"{OUT_ROOT}/other prompts"
NOTES = f"{OUT_ROOT}/notes and other"
LINKS = f"{OUT_ROOT}/links"
COMMANDS = f"{OUT_ROOT}/commands and code"
MAX_CLIP_CHARS = 20_000       # longer clips are left alone (a 56 MB TSV was once copied)
LLM_CHARS = 800

# ---- 1. junk rules -------------------------------------------------------------------
_PATH_RE = re.compile(r'^\s*"?(?:[A-Za-z]:[\\/]|\\\\[\w.-]+\\|file://|/(?:c|home|usr|mnt)/)[^\n]*"?\s*$')
_PATH_LINES_RE = re.compile(r'(?m)^\s*"?(?:[A-Za-z]:[\\/]|\\\\[\w.-]+\\|file://)[^\n]+$')
_LOG_RE = re.compile(
    r"Traceback \(most recent call last\)|^\s*File \".+\", line \d+|\b\w*(?:Error|Exception):\s"
    r"|^\s*at .+\(.+:\d+:\d+\)|\bHTTP/1\.[01]\"? \d{3}\b|^\[?\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}"
    r"|\b(?:ERROR|WARN(?:ING)?|FATAL|DEBUG)\b[:\]]|^PS [A-Z]:\\|^\s*\$ \w+|^\s*>>> ", re.M)
_BARE_RE = re.compile(r"^\s*-?[\d.,:/ -]+\s*$|^\s*[0-9a-f]{32,64}\s*$|^\s*[A-Za-z0-9+/]{40,}={0,2}\s*$", re.I)
_GLOB_RE = re.compile(r"^\s*\*?\.\w{1,6}\s*$")          # *.png, .blob
_URL_LINE_RE = re.compile(r"^\s*https?://\S+\s*$", re.I)
_NAI_FILE_RE = re.compile(r"(?m)^\s*\S.*\bs-\d{6,}\S*\.(?:png|jpe?g|webp)\s*$", re.I)


def junk_rule(text: str) -> str:
    t = text.strip()
    if not t:
        return "empty"
    if _PATH_RE.match(t) or (len(_PATH_LINES_RE.findall(t)) >= max(1, len(t.splitlines()) // 2)
                             and _PATH_LINES_RE.search(t)):
        return "file path"
    if _NAI_FILE_RE.search(t) and len(t.splitlines()) <= 3:
        return "nai filename"
    if _LOG_RE.search(t):
        return "log / error text"
    if _BARE_RE.match(t):
        return "bare number / hash"
    if _GLOB_RE.match(t):
        return "file pattern"
    if t.startswith("clippip-setup:"):
        return "keyboard setup string"
    return ""


# ---- 2. section rules ------------------------------------------------------------------
_cs = None


def _sectioner():
    global _cs
    if _cs is None:
        sys.path.insert(0, str(GALLERY_BUILD))
        import clip_section as cs  # heavy: loads prompt_sections vocab
        _cs = cs
    return _cs


def section_of(text: str) -> str:
    try:
        return _sectioner().clip_section(text).get("section") or ""
    except Exception as exc:  # a rule bug must never stop the scan
        print(f"[section] {exc}", file=sys.stderr)
        return ""


# ---- 2a. prompt gate: is this clip a NovelAI prompt snippet at all? ------------------------
# Prompt snippets go to the section rules ONLY (never the LLM); everything else goes to the LLM,
# which may not pick a prompt section. Tested 2026-10-12 against the user's own sorted tabs.
_WEIGHT_RE = re.compile(r"(?<![\w.])-?\d+(?:\.\d+)?::\s*\S|\bartis?t\s*:\s*\w|(?:source|target|mutu\w*al)#\w"
                        r"|\b1(?:girl|boy)\b|\|\|[^|\n]+\|[^\n]*\|\||\{\{+[\w ,'-]+\}\}", re.I)
_CODE_RE = re.compile(r"^\s*(?:ssh|git|python|py|pip|npm|curl|cd|tmux|netsh|mkdir|docker|irm|sudo)\b"
                      r"|&&|\$\(|[a-z]+://|^\s*[{\[]\s*[\"']", re.I | re.M)
# shell commands and one-liners: placed by rule, the small model calls any project title a "command"
_CMD_RE = re.compile(r"^\s*\(?(?:ssh|scp|git|python|py|pip|npm|npx|curl|cd|tmux|netsh|mkdir|docker|irm|iwr|sudo"
                     r"|ipconfig|ifconfig|winget|choco|gh|ollama|Get-\w+|Set-\w+|Start-\w+)\s+\S"
                     r"|^\s*[\w.-]+@[\w.-]+\s+\S*\s*[%$#]\s*$|\s&&\s|\$\(", re.I | re.M)
_GATE_WORDS = 5          # a "tag" longer than this is a sentence, not a tag
_GATE_SHARE = 0.5


def is_prompt(text: str):
    """-> (yes, why). Prompt syntax (weights, artist:, source#, ||a|b||) or mostly known tags."""
    t = text.strip()
    if _CODE_RE.search(t):
        return False, "code / link"
    if _WEIGHT_RE.search(t):
        return True, "prompt syntax"
    try:
        cs = _sectioner()
        ps = cs.ps
        known = total = 0
        for raw, nm in cs._parts(t):
            if nm == "\x00neg":
                return True, "prompt syntax"
            total += 1
            if len(nm.split()) > _GATE_WORDS or not re.search(r"[a-z]", nm, re.I):
                continue
            if ps._part_is_artist(raw, nm) or ps.classify_tag(nm, raw) != "other":
                known += 1
            if total >= 80:
                break
    except Exception as exc:
        print(f"[gate] {exc}", file=sys.stderr)
        return False, "gate error"
    if total and known / total >= _GATE_SHARE:
        return True, f"known tags {known}/{total}"
    return False, f"known tags {known}/{total}"


# ---- 3. local LLM ----------------------------------------------------------------------
_KINDS = ("note", "prompt", "junk")
_LLM_PROMPT = """You sort clipboard history clips. The clip below is NOT an AI image prompt made of known tags (those were already sorted elsewhere). Pick ONE kind:
- note: text worth keeping: a thought, a reminder, a to-do, the title or file name of a project, a message, a comment copied from a web page, a name.
- prompt: a short image description or tag the user would paste into an image prompt (e.g. "pacifier in his mouth", ":d").
- junk: ONLY clearly worthless one-time copies: program output, logs, terminal screens, random tokens.
WHEN UNSURE answer note. A short word or a name is never junk.
Answer ONLY JSON: {"kind": "note|prompt|junk", "reason": "<=8 words"}

CLIP:
"""


def llm_verdict(text: str) -> dict | None:
    body = json.dumps({
        "model": MODEL, "prompt": _LLM_PROMPT + text[:LLM_CHARS], "stream": False, "format": "json",
        "keep_alive": "2m", "options": {"temperature": 0, "num_predict": 50, "num_ctx": 2048},
    }).encode()
    req = urllib.request.Request(OLLAMA_URL, body, {"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            out = json.loads(json.loads(r.read())["response"])
    except Exception as exc:
        print(f"[llm] {exc}", file=sys.stderr)
        return None
    kind = str(out.get("kind", "")).lower()
    if kind not in _KINDS:
        return None
    if kind == "junk" and len(text.strip()) < 30:   # a short fragment is never trash
        kind = "note"
    return {"kind": kind, "reason": str(out.get("reason", ""))[:60]}


def _load_cache() -> dict:
    try:
        return json.loads(CACHE.read_text("utf-8"))
    except Exception:
        return {}


def _save_cache(cache: dict) -> None:
    if len(cache) > CACHE_MAX:
        cache = dict(list(cache.items())[-CACHE_MAX:])
    CACHE.write_text(json.dumps(cache), "utf-8")


_llm_budget = None   # None = unlimited; scheduled runs cap how many clips may go to the model


# ---- decision ----------------------------------------------------------------------------
def decide(text: str, cache: dict, use_llm: bool = True, meta: dict = None):
    """-> (dest tab, why, source). Rules only since 2026-10-12 (clippip_rules.py): no model is called."""
    if not USE_LLM:
        import clippip_rules
        tab, why = clippip_rules.classify(text, meta)
        return OUT_ROOT + "/" + tab, why, "rules"
    if len(text) > MAX_CLIP_CHARS:
        return "", "too long", "rules"
    why = junk_rule(text)
    if why:
        return TRASH, why, "rules"
    lines = [ln for ln in text.splitlines() if ln.strip()]
    if lines and all(_URL_LINE_RE.match(ln) for ln in lines):
        return LINKS, "link", "rules"
    if _CMD_RE.search(text) and len(lines) <= 6:
        return COMMANDS, "command", "rules"
    yes, gate = is_prompt(text)
    if yes:
        sec = section_of(text)
        if sec in SECTION_TABS:
            return SECTION_TABS[sec], sec, "rules"
        return OTHER_PROMPTS, "prompt, no single section (" + gate + ")", "rules"
    if not (use_llm and USE_LLM):
        return NOTES, "not a prompt", "rules"
    key = "v4:" + hashlib.sha1(text.encode("utf-8", "replace")).hexdigest()
    v = cache.get(key)
    if v is None:
        global _llm_budget
        if _llm_budget is not None:
            if _llm_budget <= 0:
                return "", "llm budget used up", "llm"
            _llm_budget -= 1
        v = llm_verdict(text)
        if v is None:
            return "", "llm unavailable", "llm"
        cache[key] = v
    dest = {"junk": TRASH, "prompt": OTHER_PROMPTS}.get(v["kind"], NOTES)
    return dest, "llm: " + (v["reason"] or v["kind"]), "llm"


# ---- CopyQ access ------------------------------------------------------------------------
def copyq(args, timeout=60) -> str:
    res = subprocess.run([COPYQ_EXE] + args, capture_output=True, timeout=timeout)
    if res.returncode != 0:
        raise RuntimeError(res.stderr.decode("utf-8", "replace").strip()[:300] or "copyq failed")
    return res.stdout.decode("utf-8", "replace")


def existing_tabs() -> list:
    return [t.strip() for t in copyq(["tab"]).splitlines() if t.strip()]


_LIST_JS = """
var name = %s, cap = %d, out = [];
var rows = ItemSelection(name).selectRemovable().rows();
tab(name);
for (var k = 0; k < rows.length; k++) {
  var r = rows[k];
  var t = str(read(mimeText, r));
  if (!t) continue;
  out.push({row: r, text: t.length > cap ? t.substr(0, cap + 1) : t});
}
print(JSON.stringify(out));
"""

_MOVE_JS = """
var src = %s, dst = %s, row = %d, head = %s, len = %d;
tab(src);
var cur = str(read(mimeText, row));
if (cur.length !== len || cur.substr(0, head.length) !== head) { print('MISMATCH'); }
else {
  var it = getItem(row);
  tab(dst);
  insert(0, it);
  tab(src);
  remove(row);
  print('OK');
}
"""


def list_clips(tab: str) -> list:
    out = copyq(["eval", "--", _LIST_JS % (json.dumps(tab), MAX_CLIP_CHARS)], timeout=120)
    return json.loads(out.strip() or "[]")


def move_clip(src: str, dst: str, row: int, text: str) -> bool:
    js = _MOVE_JS % (json.dumps(src), json.dumps(dst), row, json.dumps(text[:100]), len(text))
    return copyq(["eval", "--", js]).strip() == "OK"


# ---- phone clips (laptop clip store) ------------------------------------------------------
def phone_pass(apply: bool, limit: int, cache: dict, use_llm: bool):
    """Files text clips copied on the phone under ai_tab in the clip store (rows stay where they are).
    The ClipPiP app lists them as "ai ..." tabs. Already filed clips are skipped."""
    import sqlite3
    from contextlib import closing
    import clippip_store as store
    out, counts = [], {}
    with store._db_lock, closing(store._connect()) as con:
        rows = con.execute(
            "SELECT id, text, source_app, source_title, direction FROM clips "
            "WHERE ai_tab IS NULL AND deleted_at IS NULL AND kind = 'text' "
            "AND text IS NOT NULL ORDER BY id DESC LIMIT ?", (limit,)).fetchall()
    for cid, text, app, title, direction in rows:
        dest, why, src = decide(text, cache, use_llm=use_llm,
                                meta={"source_app": app or "", "source_title": title or "", "direction": direction or ""})
        if not dest and (why in ("llm unavailable", "llm budget used up") or (why == "unplaced" and not use_llm)):
            continue                      # leave unfiled, try again next run
        tab = dest[len(OUT_ROOT) + 1:] if dest else "unsorted"
        counts[tab] = counts.get(tab, 0) + 1
        out.append(("phone history", cid, tab, src, why, "filed" if apply else "",
                    text[:120].replace("\t", " ").replace("\n", " ")))
        if apply:
            with store._db_lock, closing(store._connect()) as con:
                con.execute("UPDATE clips SET ai_tab = ?, ai_reason = ? WHERE id = ?", (tab, why[:80], cid))
                con.commit()
    return out, counts


# ---- main --------------------------------------------------------------------------------
def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="really move clips (default: dry run)")
    ap.add_argument("--tabs", nargs="*", default=INBOX_TABS)
    ap.add_argument("--limit", type=int, default=200, help="max clips per tab per run")
    ap.add_argument("--no-llm", action="store_true")
    ap.add_argument("--no-phone", action="store_true", help="skip the phone clips of the laptop clip store")
    ap.add_argument("--no-copyq", action="store_true", help="skip the CopyQ inbox tabs")
    ap.add_argument("--scheduled", action="store_true",
                    help="quiet, gentle run for a scheduled task: lock, low priority, idle checks, log file")
    args = ap.parse_args()
    if args.scheduled:
        return scheduled_run(args)
    return run(args)


# ---- scheduled run: gentle on the system ------------------------------------------------
LOCK = HERE / "clippip_ai.lock"
LOG = HERE / "clippip_ai.log"
LOG_MAX = 200_000
SCHED_LLM_BUDGET = 30        # clips per run that may go to the model
SCHED_ROWS = 200
MIN_FREE_RAM_MB = 2500
MAX_GPU_UTIL = 50            # percent
MAX_GPU_MEM_MB = 4500


def _log(msg: str) -> None:
    try:
        if LOG.exists() and LOG.stat().st_size > LOG_MAX:
            LOG.write_text("", "utf-8")
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + msg + "\n")
    except OSError:
        pass


def _gpu_busy() -> str:
    """'' when the GPU is calm (or there is none), otherwise why it is not."""
    try:
        out = subprocess.run(
            ["nvidia-smi", "--query-gpu=utilization.gpu,memory.used", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=10, creationflags=0x08000000).stdout.strip().splitlines()
        util, mem = [int(x) for x in out[0].split(",")]
    except Exception:
        return ""
    if util > MAX_GPU_UTIL:
        return f"gpu busy ({util}%)"
    if mem > MAX_GPU_MEM_MB:
        return f"gpu memory in use ({mem} MB)"
    return ""


def _pending_phone_rows() -> int:
    from contextlib import closing
    import clippip_store as store
    with store._db_lock, closing(store._connect()) as con:
        return con.execute("SELECT count(*) FROM clips WHERE ai_tab IS NULL AND deleted_at IS NULL "
                           "AND kind = 'text' AND text IS NOT NULL").fetchone()[0]


def scheduled_run(args) -> int:
    global _llm_budget
    import psutil
    if LOCK.exists():
        try:
            pid = int(LOCK.read_text().strip())
            if psutil.pid_exists(pid) and "clippip_ai" in " ".join(psutil.Process(pid).cmdline()):
                return 0                                  # a run is still going
        except Exception:
            pass
    LOCK.write_text(str(os.getpid()))
    try:
        psutil.Process().nice(psutil.BELOW_NORMAL_PRIORITY_CLASS)
        n = _pending_phone_rows()
        if n == 0:
            return 0                                      # nothing new: no model, no vocab, no log line
        free = psutil.virtual_memory().available // 2**20
        if free < MIN_FREE_RAM_MB:
            _log(f"skip: only {free} MB RAM free, {n} clips waiting")
            return 0
        busy = _gpu_busy()
        use_llm = not busy
        _llm_budget = SCHED_LLM_BUDGET
        cache = _load_cache()
        rows, counts = phone_pass(True, SCHED_ROWS, cache, use_llm)
        _save_cache(cache)
        _log(f"filed {len(rows)} of {n} waiting" + (f" (rules only, {busy})" if busy else "")
             + " " + json.dumps(counts))
    except Exception as exc:
        _log(f"error: {exc!r}")
        return 1
    finally:
        try:
            LOCK.unlink()
        except OSError:
            pass
    return 0


def run(args) -> int:
    have = set(existing_tabs())
    cache = _load_cache()
    rows_out, moved, counts = [], 0, {}
    for tab in ([] if args.no_copyq else args.tabs):
        if tab not in have:
            print(f"[skip] no such tab {tab!r}")
            continue
        clips = list_clips(tab)[: args.limit]
        # highest row first so earlier removals do not shift the rows still to do
        decided = []
        for c in clips:
            dest, why, src = decide(c["text"], cache, use_llm=not args.no_llm)
            decided.append((c["row"], c["text"], dest, why, src))
        for row, text, dest, why, src in sorted(decided, key=lambda d: -d[0]):
            ok = ""
            if dest and args.apply:
                try:
                    ok = "moved" if move_clip(tab, dest, row, text) else "changed, skipped"
                except Exception as exc:
                    ok = f"error: {exc}"
                moved += ok == "moved"
            counts[dest or "(left)"] = counts.get(dest or "(left)", 0) + 1
            rows_out.append((tab, row, dest or "(left)", src, why, ok,
                             text[:120].replace("\t", " ").replace("\n", " \\n ")))
    if not args.no_phone:
        prows, pcounts = phone_pass(args.apply, args.limit, cache, not args.no_llm)
        rows_out += prows
        for k, v in pcounts.items():
            counts["phone -> " + k] = v
            moved += args.apply and v
    _save_cache(cache)
    with open(REPORT, "w", encoding="utf-8", newline="") as f:
        f.write("tab\trow\tdest\tsource\treason\tresult\ttext\n")
        for r in rows_out:
            f.write("\t".join(str(x) for x in r) + "\n")
    mode = "APPLIED" if args.apply else "DRY RUN"
    print(f"{mode}: {len(rows_out)} clips, moved {moved}. Report: {REPORT}")
    for k, v in sorted(counts.items(), key=lambda kv: -kv[1]):
        print(f"  {v:5d}  {k}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
