"""Pure text transforms for NAI prompt clips.

Python port of the transforms in
`tampermonkey\\NAI Prompt Tools - Prompt edit Hotkeys (v2.3.0)-backup.user.js`
plus the multichar prefix actions, which that script does not have.

Every transform is a pure function. Nothing here touches the clipboard, the
clip store, the network or the disk, so the same code serves ClipPiP's
transform sheet, CopyQ commands and any CLI use.

Two shapes:
  selection transforms  f(text) -> text      applied to the selected substring
  document transforms   f(text, start, end) -> (text, start, end)

Use apply() for both; it handles the selection slicing and the caret.

Registry: TRANSFORMS (ordered), registry() for the JSON the phone renders.
"""
from __future__ import annotations

import re
from typing import Callable

MAX_CHARS = 20_000      # a 56 MB Everything TSV was once copied to the clipboard


# ---------- weight / separator normalization ----------

_NW_MULTILINE_WEIGHT = re.compile(
    r"(\d+(?:\.\d+)?)::\s*\n+\s*([^:\n].*?)\s*\n+\s*::", re.S)
_NW_MISSING_COMMA = re.compile(r"::\s*(?=\d+(?:\.\d+)?::)")
_SPACED_COMMA = re.compile(r"\s*,\s*")
_DOUBLE_COMMA = re.compile(r",\s*,+")


def normalize_weights(raw: str) -> str:
    t = raw.replace("\r\n", "\n")
    t = _NW_MULTILINE_WEIGHT.sub(lambda m: f"{m.group(1)}::{m.group(2).strip()}::", t)
    t = _NW_MISSING_COMMA.sub("::, ", t)
    t = _SPACED_COMMA.sub(", ", t)
    t = _DOUBLE_COMMA.sub(", ", t)
    return t


# ---------- tokenizers ----------

_SPLIT_COMMA_OR_NL = re.compile(r"\s*,\s*|\n+")
_SPLIT_LOOSE = re.compile(r"\s*,\s*|\n+|\s{2,}")


def _split_comma_or_nl_safe(t: str) -> list[str]:
    t = normalize_weights(t).replace("\r\n", "\n")
    return [x.strip() for x in _SPLIT_COMMA_OR_NL.split(t) if x.strip()]


def _split_loose_safe(t: str) -> list[str]:
    t = normalize_weights(t).replace("\r\n", "\n")
    return [x.strip() for x in _SPLIT_LOOSE.split(t) if x.strip()]


# ---------- randomizers ----------

_RAND_BLOCK = re.compile(r"\|\|(.*?)\|\|", re.S)
_EDGE_PIPES = re.compile(r"^\|+|\|+$")
_PIPE_RUN = re.compile(r"\|+")
_WRAPPED = re.compile(r"^\s*\|\|.*\|\|\s*$", re.S)


def join_rand_blocks(t: str) -> str:
    """||A|| + ||B|| -> ||A|B||"""
    found = _RAND_BLOCK.findall(t)
    if len(found) < 2:
        return t
    return "||" + "|".join(found) + "||"


def unwrap_pipes(t: str) -> str:
    """Remove ||, turn remaining | into commas."""
    if not t:
        return t
    out = re.sub(r"\|\s*,", ",", t)
    out = re.sub(r",\s*\|", ",", out)
    out = _EDGE_PIPES.sub("", out)
    out = _PIPE_RUN.sub(", ", out)
    out = _SPACED_COMMA.sub(", ", out).strip()
    out = re.sub(r"^,\s*|\s*,$", "", out)
    return out


def fix_rand_format(t: str) -> str:
    """||A|B||C|D|| -> ||A|B|C|D|| (double pipes only at the edges)."""
    if not t:
        return t
    clean = t.strip()
    clean = _EDGE_PIPES.sub("", clean)
    clean = _PIPE_RUN.sub("|", clean)
    return f"||{clean}||"


def pipes_wrap(t: str) -> str:
    """comma/newline separated -> ||a|b|c||; already wrapped is left alone."""
    if _WRAPPED.match(t):
        return t.strip()
    joined = "|".join(_split_comma_or_nl_safe(t))
    joined = _EDGE_PIPES.sub("", joined)
    return f"||{joined}||"


def wrap_only(t: str) -> str:
    return f"||{t}||"


def mix_with_comma(t: str) -> str:
    """Flatten lines, then ||...|,|| so the randomizer can also pick nothing."""
    fixed = re.sub(r"([^,])\s*[\r\n]+", r"\1,", t)
    fixed = re.sub(r"[\r\n]+", " ", fixed)
    fixed = _SPACED_COMMA.sub(",", fixed)
    return f"||{fixed.strip()}|,||"


# ---------- weights ----------

_LEADING_WEIGHT = re.compile(r"^\s*(-?\d+(?:\.\d+)?)::")
_TRAILING_COLONS = re.compile(r"::\s*$")


def _weight_lines(t: str, w: str) -> str:
    out = []
    for s in re.split(r"\r?\n", t):
        line = s.strip()
        if not line:
            continue
        if re.search(r"\d$", line):
            line += ","      # a trailing digit would fuse with the closing ::
        out.append(f"{w}::{line}::")
    return "\n".join(out)


def weight_1(t: str) -> str:
    return _weight_lines(t, "1.0")


def weight_05(t: str) -> str:
    return _weight_lines(t, "0.5")


def neg2(t: str) -> str:
    """Whole selection as -2::...:: , replacing any weight it already had."""
    inner = _LEADING_WEIGHT.sub("", t)
    inner = _TRAILING_COLONS.sub("", inner).strip()
    if re.search(r"\d$", inner):
        inner += ","
    return f"-2::{inner}::"


def _fmt_weight(v: float) -> str:
    s = f"{v:.2f}".rstrip("0").rstrip(".")
    if "." not in s:
        s += ".0"
    return s


def weight_step(t: str, delta: float) -> str:
    """The stepper: nudge an existing weight, or add one at 1.0 +/- delta."""
    m = _LEADING_WEIGHT.match(t)
    if m:
        inner = _TRAILING_COLONS.sub("", t[m.end():]).strip()
        new = round(float(m.group(1)) + delta, 2)
    else:
        inner = t.strip()
        new = round(1.0 + delta, 2)
    if not inner:
        return t
    if re.search(r"\d$", inner):
        inner += ","
    return f"{_fmt_weight(new)}::{inner}::"


def weight_up(t: str) -> str:
    return weight_step(t, 0.1)


def weight_down(t: str) -> str:
    return weight_step(t, -0.1)


# ---------- braces ----------

def brace_wrap(t: str) -> str:
    return "{" + t + "}"


def brace_unwrap(t: str) -> str:
    if t.startswith("{") and t.endswith("}"):
        return t[1:-1]
    return t


# ---------- separators ----------

def dupe_sel(t: str) -> str:
    return f"{t}, {t}" if t else t


def strip_linebreaks(t: str) -> str:
    out = re.sub(r"\r?\n+", " ", t)
    return re.sub(r"\s{2,}", " ", out).strip()


def comma_to_nl(t: str) -> str:
    normalized = re.sub(r"\r?\n+", " ", normalize_weights(t))
    parts = [x.strip() for x in _SPACED_COMMA.split(normalized) if x.strip()]
    return "\n".join(p + "," for p in parts)


def nl_to_comma(t: str) -> str:
    return ", ".join(s.strip() for s in re.split(r"\r?\n", t) if s.strip())


def insert_commas(t: str) -> str:
    return ", ".join(_split_loose_safe(t))


def collapse_nl1(t: str) -> str:
    n = t.replace("\r\n", "\n")
    n = re.sub(r"[ \t]+\n", "\n", n)
    n = re.sub(r"\n{2,}", "\n", n)
    return n


def dedupe_tags(t: str) -> str:
    """Drop repeated tags, keep the first occurrence and the original order."""
    seen: set[str] = set()
    out = []
    for tag in _split_comma_or_nl_safe(t):
        key = tag.casefold()
        if key in seen:
            continue
        seen.add(key)
        out.append(tag)
    return ", ".join(out)


# ---------- multichar prefixes (new: no userscript does this) ----------

PREFIXES = ("source#", "target#", "mutual#")
_PREFIX_RE = re.compile(r"(?i)^(?:source|target|mutual)#")
# a tag, optionally wrapped in w::...:: , so the prefix lands on the tag itself
_WEIGHT_WRAP = re.compile(r"^(\s*-?\d+(?:\.\d+)?::\s*)(.*?)(\s*::\s*)$", re.S)
_KEEP_SEPS = re.compile(r"([,\n]+)")


def _per_tag(t: str, fn: Callable[[str], str]) -> str:
    """Map fn over every tag, leaving the original separators untouched."""
    out = []
    for piece in _KEEP_SEPS.split(t):
        if not piece or _KEEP_SEPS.fullmatch(piece):
            out.append(piece)
            continue
        lead = piece[:len(piece) - len(piece.lstrip())]
        trail = piece[len(piece.rstrip()):]
        body = piece.strip()
        if not body:
            out.append(piece)
            continue
        m = _WEIGHT_WRAP.match(body)
        if m:
            body = m.group(1) + fn(m.group(2)) + m.group(3)
        else:
            body = fn(body)
        out.append(lead + body + trail)
    return "".join(out)


def _set_prefix(prefix: str) -> Callable[[str], str]:
    def inner(tag: str) -> str:
        return prefix + _PREFIX_RE.sub("", tag)
    return inner


def prefix_source(t: str) -> str:
    return _per_tag(t, _set_prefix("source#"))


def prefix_target(t: str) -> str:
    return _per_tag(t, _set_prefix("target#"))


def prefix_mutual(t: str) -> str:
    return _per_tag(t, _set_prefix("mutual#"))


def strip_prefix(t: str) -> str:
    return _per_tag(t, lambda tag: _PREFIX_RE.sub("", tag))


def swap_source_target(t: str) -> str:
    def inner(tag: str) -> str:
        m = _PREFIX_RE.match(tag)
        if not m:
            return tag
        rest = tag[m.end():]
        low = m.group(0).lower()
        if low == "source#":
            return "target#" + rest
        if low == "target#":
            return "source#" + rest
        return tag
    return _per_tag(t, inner)


# ---------- document transforms (need the caret, not just the text) ----------

def _move_lines(text: str, ss: int, se: int, direction: str):
    lines = text.split("\n")
    last = len(lines) - 1

    def offset_to_line(off: int) -> int:
        count = 0
        for i, ln in enumerate(lines):
            count += len(ln) + 1
            if off < count:
                return i
        return last

    def line_to_offset(li: int) -> int:
        return sum(len(lines[i]) + 1 for i in range(li))

    start_line = offset_to_line(ss)
    end_line = offset_to_line(se)
    # a selection ending at column 0 does not own that line
    if se > ss and se == line_to_offset(end_line):
        end_line -= 1
    if end_line < start_line:
        end_line = start_line

    if direction == "up" and start_line == 0:
        return None
    if direction == "down" and end_line == last:
        return None

    block = lines[start_line:end_line + 1]
    if direction == "up":
        new_lines = (lines[:start_line - 1] + block
                     + [lines[start_line - 1]] + lines[end_line + 1:])
        new_start_line = start_line - 1
    else:
        new_lines = (lines[:start_line] + [lines[end_line + 1]]
                     + block + lines[end_line + 2:])
        new_start_line = start_line + 1

    new_end_line = new_start_line + (end_line - start_line)
    orig_col_start = ss - line_to_offset(start_line)
    orig_col_end = se - line_to_offset(end_line)

    def new_line_to_offset(li: int) -> int:
        return sum(len(new_lines[i]) + 1 for i in range(li))

    new_start = new_line_to_offset(new_start_line) + min(
        orig_col_start, len(new_lines[new_start_line]))
    # orig_col_end can sit one past the end of the line; keep that position
    new_end = new_line_to_offset(new_end_line) + min(
        orig_col_end, len(new_lines[new_end_line]) + 1)
    return "\n".join(new_lines), new_start, new_end


def move_up(text: str, start: int, end: int):
    return _move_lines(text, start, end, "up")


def move_down(text: str, start: int, end: int):
    return _move_lines(text, start, end, "down")


# ---------- registry ----------

class Transform:
    __slots__ = ("id", "label", "group", "fn", "scope")

    def __init__(self, tid: str, label: str, group: str, fn, scope: str = "selection"):
        self.id = tid
        self.label = label
        self.group = group
        self.fn = fn
        self.scope = scope


TRANSFORMS: tuple[Transform, ...] = (
    # weights
    Transform("weight1", "Weight each line 1.0::", "weights", weight_1),
    Transform("weight05", "Weight each line 0.5::", "weights", weight_05),
    Transform("weightUp", "Weight +0.1", "weights", weight_up),
    Transform("weightDown", "Weight -0.1", "weights", weight_down),
    Transform("neg2", "Negative whole (-2::...::)", "weights", neg2),
    Transform("braceWrap", "Brace {more}", "weights", brace_wrap),
    Transform("braceUnwrap", "Unbrace", "weights", brace_unwrap),
    # randomizers
    Transform("pipesWrap", "Pipes + wrap ||a|b||", "randomizers", pipes_wrap),
    Transform("wrapOnly", "Wrap with ||", "randomizers", wrap_only),
    Transform("joinRandBlocks", "Join randomizers", "randomizers", join_rand_blocks),
    Transform("fixRandFormat", "Fix randomizer", "randomizers", fix_rand_format),
    Transform("unwrapPipes", "Unwrap randomizer", "randomizers", unwrap_pipes),
    Transform("mixWithComma", "Mix with comma ||a|,||", "randomizers", mix_with_comma),
    # separators
    Transform("commaToNL", "Comma -> new lines", "separators", comma_to_nl),
    Transform("nlToComma", "New lines -> comma", "separators", nl_to_comma),
    Transform("insertCommas", "Insert missing commas", "separators", insert_commas),
    Transform("stripLinebreaks", "Remove line breaks", "separators", strip_linebreaks),
    Transform("collapseNL1", "Collapse newlines", "separators", collapse_nl1),
    Transform("dupeSel", "Duplicate (tag -> tag, tag)", "separators", dupe_sel),
    Transform("dedupeTags", "Dedupe tags", "separators", dedupe_tags),
    # multichar
    Transform("prefixSource", "Prepend source#", "multichar", prefix_source),
    Transform("prefixTarget", "Prepend target#", "multichar", prefix_target),
    Transform("prefixMutual", "Prepend mutual#", "multichar", prefix_mutual),
    Transform("swapSourceTarget", "Swap source# / target#", "multichar", swap_source_target),
    Transform("stripPrefix", "Remove source#/target#", "multichar", strip_prefix),
    # lines
    Transform("moveUp", "Move line(s) up", "lines", move_up, "document"),
    Transform("moveDown", "Move line(s) down", "lines", move_down, "document"),
)

BY_ID = {t.id: t for t in TRANSFORMS}

GROUP_LABELS = {
    "weights": "Weights",
    "randomizers": "Randomizers",
    "separators": "Separators",
    "multichar": "Multichar",
    "lines": "Lines",
}


def registry() -> list[dict]:
    """What the phone renders the transform sheet from."""
    return [{"id": t.id, "label": t.label, "group": t.group,
             "group_label": GROUP_LABELS.get(t.group, t.group),
             "scope": t.scope} for t in TRANSFORMS]


class TransformError(ValueError):
    pass


def apply(action: str, text: str, start: int | None = None,
          end: int | None = None) -> dict:
    """Run one transform. Returns {text, start, end, changed}.

    start/end default to the whole text. A selection transform sees only the
    selected substring and the caret is left selecting the replacement.
    """
    t = BY_ID.get(action)
    if t is None:
        raise TransformError(f"unknown transform: {action}")
    if text is None:
        raise TransformError("no text")
    if len(text) > MAX_CHARS:
        raise TransformError(f"clip is too long ({len(text)} > {MAX_CHARS} chars)")

    n = len(text)
    s = 0 if start is None else max(0, min(int(start), n))
    e = n if end is None else max(0, min(int(end), n))
    if e < s:
        s, e = e, s

    if t.scope == "document":
        res = t.fn(text, s, e)
        if res is None:                      # already at the top or bottom
            return {"text": text, "start": s, "end": e, "changed": False}
        new_text, new_start, new_end = res
        return {"text": new_text, "start": new_start, "end": new_end,
                "changed": new_text != text}

    if s == e:                               # no selection = whole text
        s, e = 0, n
    out = t.fn(text[s:e])
    new_text = text[:s] + out + text[e:]
    return {"text": new_text, "start": s, "end": s + len(out),
            "changed": new_text != text}
