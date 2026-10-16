"""Rule based clip sorter for ClipPiP (no AI model). classify(text, meta) -> (tab, why).

Built 2026-10-12 from the kinds of clips in the user's own CopyQ tabs and Ditto groups:
NovelAI prompt pieces (sections come from the gallery's prompt sectioner), negatives, whole
prompts, video prompts, seeds, NAI file names, file paths, Everything searches, links, lora
ids, hashes, commands, code, terminal/log dumps, Claude session titles, and plain notes.
The first rule that matches wins, so the order below matters. Pure functions, no state.
"""
from __future__ import annotations

import re

HEAD = 4000            # rules look at the start of a clip only; a 200 KB clip costs the same as a short one

# ---- tabs ---------------------------------------------------------------------------------
SEEDS = "seeds"
NAI_FILES = "nai file names"
PATHS = "file paths"
SEARCHES = "everything searches"
LINKS = "links"
LORAS = "lora ids"
HASHES = "hashes and tokens"
COMMANDS = "commands and code"
TERMINAL = "terminal and logs"
TITLES = "session titles"
NOTES = "notes and other"
NEGATIVES = "negatives (uc)"
FULL = "full prompts"
VIDEO = "video prompts"
OTHER_PROMPTS = "other prompts"
SECTION_TABS = {
    "artist_mix": "artist mixes", "artist": "artists", "character": "characters", "body": "body",
    "face": "faces", "sex_acts": "sex acts", "clothes": "clothes", "text": "text and dialogue",
    "multichar": "multichar", "pose": "poses",
}
_SEC_LABELS = ("pose", "sex_acts", "clothes", "body", "face", "character", "scene")
_SEC_TAB = {"pose": "poses", "sex_acts": "sex acts", "clothes": "clothes", "body": "body", "face": "faces",
            "character": "characters", "scene": "backgrounds"}

# ---- not a prompt ---------------------------------------------------------------------------
_SEED_LINE = re.compile(r"^\s*\d{5,10}\s*$")
_NAI_FILE = re.compile(r"(?:^|[\s_])s-\d{6,}(?:_\w+)?(?:\s*\(lid \d+\))?(?:\.(?:png|jpe?g|webp))?\s*\"?\s*$", re.I)
_NAI_SEED = re.compile(r"(?:^|[\s_])s-\d{6,}")
_PATH_LINE = re.compile(r'^\s*[\'"]?(?:[A-Za-z]:[\\/]|\\\\[\w.-]+\\|file://|~[\\/]|/(?:c|home|usr|mnt|Users)/)[^\n]*$')
_URL_LINE = re.compile(r"^\s*https?://\S+\s*$", re.I)
_BARE_HOST = re.compile(r"^\s*(?:[a-z0-9-]+\.)+(?:com|net|org|io|la|me|to|app|dev|gg|tv|xyz|win)(?:/\S*)?\s*$", re.I)
_SEARCH = re.compile(
    r"(?:^|[\s!<(|])(?<![\w:])(?:comment|regex|multiline|date-modified|datemodified|dm|dc|includefilelist|hard-link-filenames"
    r"|naigens\d*|nopath|wfn|startwith|endwith|content|parent|ext|size|width|height|case|file|folder|path):(?![:\s/])\S"
    r"|<<[^>]*>>", re.I)
_LORA = re.compile(r"^\s*urn:air:\S+\s*$", re.I)
_HASH = re.compile(r"^[A-Za-z0-9+/]{40,}={0,2}$|^[0-9a-f]{32,64}$|^[A-Za-z0-9_#-]{36,}$", re.I)
_SETUP = re.compile(r"^clippip-setup:", re.I)
_GLOB = re.compile(r"^\s*\*?\.\w{1,6}\s*$")
_BARE = re.compile(r"^\s*[\d.,:/ +()-]{3,}\s*$")                  # ip, ip:port, phone number, date

_TERMINAL = re.compile(
    r"Claude Code v\d|[▐▛▜█▝▘]{3}|^\s*[●⎿❯]\s|# Codex conversation"
    r"|Traceback \(most recent call last\)|^\s*File \".+\", line \d+|\b\w*(?:Error|Exception):\s"
    r"|^\s*at .+\(.+:\d+:\d+\)|\bHTTP/1\.[01]\"? \d{3}\b|^\[?\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}|^\[\d{2}:\d{2}:\d{2}\]"
    r"|^\w{3} \d{1,2} \d{2}:\d{2}:\d{2} \S+ \S+\[\d+\]|\b(?:ERROR|WARN(?:ING)?|FATAL|DEBUG)\b[:\]]"
    r"|^Error: |^Listening on \d|\(ctrl\+o to expand\)|^\s*[\w.-]+@[\w.-]+\s+\S*\s*[%$#]\s*$|^\{'ok': ", re.M)
_CODE = re.compile(
    r"^\s*#(?:Requires|NoEnv|SingleInstance|Include)\b|^\s*// ==UserScript==|^\s*(?:def|class|function|import|from|param|const|let|var"
    r"|public|private|using|package)\b[^\n]*[({:;]\s*$|^\s*(?:import|from) [\w.]+|^\s*\$\w+\s*=|^\s*[\w.-]+:\s*$\n\s+[\w-]+:"
    r"|^\s*[{\[]\s*$|^\s*\{\s*\"[\w-]+\"\s*:|^\s*[\^!+#~*$]*[A-Za-z]\w*(?: & \w+)?::\s*\{?\s*$|^\s*;\s?[-=A-Za-z]"
    r"|\bSend\(|^\s*\w+ := \S|^\s*if \(.+\) \{\s*$|^\s*\"[\w-]+\"\s*:\s*[\[{\"]|^\s*\[\w+\]\s*$\n\s*\w+=", re.M)
_CODE_STRONG = re.compile(r"==UserScript==|#Requires|#NoEnv|^\s*(?:def|function|class|param)\b|\bSend\(|^\s*\[\w+\]\s*$", re.M)
_CMD = re.compile(
    r"^\s*(?:&\s*)?\(?(?:ssh|scp|git|python|pip|npm|npx|curl|wget|tmux|netsh|mkdir|docker|irm|iwr|sudo|magick"
    r"|ffmpeg|exiftool|copyq|ipconfig|ifconfig|winget|choco|scoop|ollama|pwsh|powershell|taskkill|manage-bde|schtasks|rclone"
    r"|es\.exe|robocopy|fsutil|xcopy|icacls|wsl|adb|chmod|sfc|dism|bcdedit|nvidia-smi)(?:\s+\S|\s*$)"
    r"|^\s*\.[\\/][\w.-]+\.(?:ps1|bat|py|ahk|vbs|exe)\b"
    r"|^\s*(?:Get|Set|Start|Stop|Restart|New|Remove|Add|Enable|Disable|Invoke|Test|Select|Where|Copy|Move|Register|Import"
    r"|Export)-[A-Z]\w+\b"
    r"|^\s*&?\s*\"[^\"\n]+\.(?:exe|ps1|bat|py|ahk)\"(?:\s+\S|\s*$)|^\s*[\w.-]+\.(?:ps1|bat|py|ahk|vbs)\s*$"
    r"|^\s*cd\s+['\"/\\.~\w]\S*[\\/]|^\s*(?:net|sc) (?:stop|start|use|query|config)\b|^\s*gh (?:pr|run|repo|api|auth)\b"
    r"|^\s*/\w+ \w+:\S|^\s*/[\w-]+=\S|\s&&\s|\$\(|\$(?:_|args|true|false|null|env:)|^\s*& \{|^\s*(?:bash|sh) \S+\.sh\b",
    re.I | re.M)
_TITLE_MARK = re.compile(r"\((?:wip|untested|unverified|done|open|pinned)\)|\bconversation-\d{4}-\d{2}-\d{2}", re.I)
_TITLE_TAIL = re.compile(r"\((?:wip|untested|unverified|done|open|pinned)\)(?:\.txt?)?\s*$|\b(?:pt|part)\s?\d+\b"
                         r"|\bconversation-\d{4}-\d{2}-\d{2}-\d+\.txt\s*$|^[^\n]{3,90}\.txt\s*$", re.I)

# ---- prompts ---------------------------------------------------------------------------------
_WEIGHT = re.compile(r"(?<![\w.])-?\d+(?:\.\d+)?::\s*\S|\bartis?t\s*:\s*\w|(?:source|target|mutu\w*al)#\w"
                     r"|\b[12](?:girl|boy)s?\b|\|\|[^|\n]+\|[^\n]*\|\||^\s*\|\|[^|\s]|\{\{+[\w ,'()-]+\}\}|\[\[+[\w ,'()-]+\]\]",
                     re.I | re.M)
_NEG_BLOCK = re.compile(r"(?<![\w.])(-?\d+(?:\.\d+)?)::")
_UC_WORDS = re.compile(
    r"\b(?:worst quality|bad quality|normal quality|low ?res|blurry|jpeg artifacts|bad anatomy|anatomical error|bad hands"
    r"|extra (?:digits?|fingers|arms|legs|limbs)|mutation|deformed|displeasing|watermark|signature|artist name|logo|text"
    r"|cropped(?: \w+)?|out of frame|multiple views|outside border|white border|empty background|simple background"
    r"|pillarboxed|letterboxed|halftone|censor(?:ed|ing)?|mosaic|ugly|fat|chubby|overweight|clones|2koma|lowres"
    r"|upscaled|artistic error|film grain|scan artifacts|noise|grain|missing \w+|extra \w+|disembodied|de?attached"
    r"|floating \w+|wrong \w+|\w+ error|twisted|phasing|disconnected|double \w+|2boys|multiple (?:boys|girls)|old (?:man|male)"
    r"|adult (?:male|boy|face)|picture-in-picture|split screen|glowing|outline|futanari|muscular \w+|obese)\b", re.I)
_BRACES_ONLY = re.compile(r"^[\s,]*(?:\{{3,}[^{}]*\}*[\s,{}]*)+$")
_EMOTICON = re.compile(r"^[\s,]*(?=\S*[:;=^>_@])[:;=xX>^@0-9oOdDpPqQ_.<~*'()|/3-]{2,5}[\s,]*$")
_LEET = re.compile(r"^(?=[a-z_]*[013457][a-z_]+[013457])[a-z013457_]{5,14}$")
_HAS_QUOTE = re.compile(r"[\"\u201c][^\"\u201d]{3,}[\"\u201d]")
_KEYWORDS = {
    "faces": r"face|eyes?|tongue|lips?|mouth|ahegao|blush|smile|smirk|grin|expression|looking|tears?|drool|eyebrows?|makeup|lipstick|wink",
    "body": r"breasts?|boobs|ass|hips|thighs?|waist|butt|curvy|belly|nipples?|skin|sweat|oiled|tall|muscular|figure|legs|feet|abs",
    "clothes": r"dress|shirt|skirt|pants|bra|panties|thong|bikini|lingerie|stockings|thighhighs|heels|boots|jacket|hoodie|uniform"
               r"|costume|outfit|earrings?|glasses|necklace|collar|leotard|swimsuit|jeans|shorts|socks|gloves|choker|corset",
    "sex acts": r"sex|penis|pussy|vaginal?|anal|cum|oral|fellatio|penetration|missionary|doggy\w*|cowgirl|lying|standing|sitting"
                r"|kneeling|squatting|bent over|from (?:behind|above|below|side)|view|shot|pov|spread|grab\w*|groping|kiss\w*"
                r"|licking|straddl\w+|riding|pose|focus|angle|close-?up|netorare|interracial|ejaculation|handjob|paizuri",
    "backgrounds": r"bedroom|bed|room|kitchen|bathroom|outdoors|indoors|background|night|office|park|beach|pool|classroom|street"
                   r"|alley\w*|forest|gym|lighting|window|couch|sofa",
}
_KEYWORD_RES = {k: re.compile(r"(?i)\b(?:" + v + r")\b") for k, v in _KEYWORDS.items()}
_QUOTED = re.compile(r"^\s*[\"“][^\"”\n]{2,}[\"”]\s*$")
_TEXT = re.compile(r"(?i)\btext\s*:|\bspeech bubbles?\b|\bthought bubbles?\b|\bwith the text\s*:|\bwriting on\b|\bwritten (?:on|across)\b"
                   r"|\bsound effects?\b|\btext on (?:her|his|the)\b|\blogo text\b|\b(?:english|body|clothes|underwear) text\b")
_VIDEO = re.compile(r"(?i)\b(?:motion|rhythm(?:ic)?|bouncing|bobbing|jiggl\w+ physics|slow(?:ly)?|fast(?:er)?|then (?:she|he|the)"
                    r"|camera|close-?up shot|video|\d+ ?fps|flies in|pounding|thrust(?:s|ing)?|grinding|rocking|twerk\w*"
                    r"|emphasizing|deformation|back and forth|up-and-down)\b")
_CHAR_NAME = re.compile(r"^\s*[,{\[\d.:]*\s*[\w .'\-;!&]+?[ _]\([\w .:;'!&\-]+\)(?:\s*\([\w .]+\))?\s*[,}\]:]*\s*$")
_COUNT = re.compile(r"(?i)\b(?:nsfw|[12](?:girl|boy)s?|solo)\b")
_PROSE_END = re.compile(r"[a-z]{3}[.!?](?:\s|$)")

_GATE_WORDS = 5          # a "tag" longer than this is a sentence, not a tag
_GATE_SHARE = 0.5
_CHAR_MAX_TAGS = 4       # a character clip is a name (plus series / a tag or two), not a paragraph
_FULL_TAGS = 12


def _lines(text: str) -> list:
    return [ln for ln in text.splitlines() if ln.strip()]


def _norm_title(s: str) -> str:
    s = re.sub(r"^[^\w(\[]+", "", s or "").lower()
    s = re.sub(r"\.txt?$", "", " ".join(s.split()))
    return s


def _is_title(text: str, meta: dict) -> bool:
    """A Claude / terminal session title: the copied text is the window title it was copied in."""
    t = _norm_title(text)
    if not (3 <= len(t) <= 110) or "\n\n" in text.strip():
        return False
    win = _norm_title(meta.get("source_title", ""))
    if win and len(win) >= 6 and (t.startswith(win[:max(6, len(win) - 2)]) or win.startswith(t)):
        return True
    return False


def not_prompt(text: str, meta: dict):
    """-> (tab, why) for a clip that is recognisably not a prompt, else None."""
    t = text.strip()
    head = t[:HEAD]
    lines = _lines(head)
    if not lines:
        return "trash review", "empty"
    one = len(lines) == 1
    if all(_SEED_LINE.match(ln) for ln in lines):
        return SEEDS, "seed"
    if _SETUP.match(t) or _GLOB.match(t):
        return "trash review", "setup string / file pattern"
    if all(_LORA.match(ln) or _LEET.match(ln.strip()) for ln in lines):
        return LORAS, "lora urn / trigger word"
    if all(_URL_LINE.match(ln) or _BARE_HOST.match(ln) for ln in lines):
        return LINKS, "link"
    if _TERMINAL.search(head):
        return TERMINAL, "terminal / log text"
    paths = sum(1 for ln in lines if _PATH_LINE.match(ln))
    if _SEARCH.search(head) and not _WEIGHT.search(head.split(":", 1)[0]):
        return SEARCHES, "everything search"
    seeded = sum(1 for ln in lines if _NAI_FILE.search(ln))
    if seeded and seeded >= len(lines) * 0.6 and "::" not in head:
        return NAI_FILES, "nai file name"
    if paths and paths >= max(1, len(lines) // 2):
        return PATHS, "file path"
    if all(_HASH.match(ln.strip()) for ln in lines):
        return HASHES, "hash / token"
    if len(t) <= 220 and len(lines) <= 3 and _TITLE_MARK.search(" ".join(t.split())) and "::" not in t:
        return TITLES, "session title"
    cmds = sum(1 for ln in lines if _CMD.search(ln))
    if cmds and (len(lines) <= 3 or cmds >= 0.34 * len(lines)) and not (_WEIGHT.search(head) and len(lines) > 8):
        return COMMANDS, "command"
    code_hits = len(_CODE.findall(head))
    if (code_hits >= 2 or (code_hits and len(lines) >= 6)) and (_CODE_STRONG.search(head) or not _WEIGHT.search(head)):
        return COMMANDS, "code"
    if _is_title(t, meta):
        return TITLES, "session title"
    if one and _BARE.match(t):
        return HASHES, "number / address"
    return None


def _tags(text: str):
    """(known, total, labels) over the clip's tags; known = the prompt vocabulary knows the tag."""
    import clippip_ai as ai
    cs = ai._sectioner()
    ps = cs.ps
    known = total = 0
    labels = []
    for raw, nm in cs._parts(text[:HEAD]):
        if nm == "\x00neg":
            labels.append("negative")
            continue
        total += 1
        if len(nm.split()) > _GATE_WORDS or not re.search(r"[a-z]", nm, re.I):
            labels.append("other")
            continue
        label = "artist_mix" if ps._part_is_artist(raw, nm) else ps.classify_tag(nm, raw)
        labels.append(label)
        if label != "other":
            known += 1
        if total >= 80:
            break
    return known, total, labels


def is_prompt(text: str):
    """-> (yes, why, labels). Prompt syntax (weights, artist:, source#, ||a|b||) or mostly known tags."""
    head = text.strip()[:HEAD]
    try:
        known, total, labels = _tags(head)
    except Exception as exc:
        return bool(_WEIGHT.search(head)), f"gate error {exc!r}"[:60], []
    if _WEIGHT.search(head):
        return True, "prompt syntax", labels
    if total and known / total >= _GATE_SHARE:
        return True, f"known tags {known}/{total}", labels
    return False, f"known tags {known}/{total}", labels


def prompt_tab(text: str, labels: list):
    """-> (tab, why) for a clip that passed the prompt gate."""
    import clippip_ai as ai
    t = text.strip()
    head = t[:HEAD]
    lines = _lines(head)
    weights = [float(w) for w in _NEG_BLOCK.findall(head)]
    uc = len(_UC_WORDS.findall(head))
    real = [x for x in labels if x not in ("count", "quality", "negative")]
    if weights and all(w < 0 for w in weights) and not re.search(r"(?m)^[^-\n]*[a-z]{3}", re.sub(r"-\d+(?:\.\d+)?::.*?::", "", head, flags=re.S)):
        return NEGATIVES, "all weights negative"
    texty = _QUOTED.match(t) or _TEXT.search(head[:160]) or _HAS_QUOTE.search(head[:200])
    if uc >= 2 and uc >= max(2, len(real) * 0.5) and not _COUNT.search(head) and not texty \
            and not any(w > 0 for w in weights):
        return NEGATIVES, f"negative words {uc}"
    if uc and _BRACES_ONLY.match(head) and "artist" not in head.lower():
        return NEGATIVES, "braced negative"
    multi = "#" in head and re.search(r"(?:source|target|mutu\w*al)#", head, re.I)
    secs = [x for x in real if x in _SEC_LABELS]
    kinds4 = set(secs)
    if _COUNT.search(head) and len(kinds4) >= 4 and len(real) >= 8 and not multi:
        return FULL, "whole prompt (" + ",".join(sorted(kinds4)) + ")"
    if secs and not _QUOTED.match(t):
        top = max(set(secs), key=secs.count)
        if secs.count(top) >= 0.6 * len(secs) and not (top == "character" and len(real) > _CHAR_MAX_TAGS):
            tags = [k for k in _BLOCK_ORDER + ("character", "scene") if secs.count(k) >= 2 or k == top]
            if multi:
                tags.append("multichar")
            return _SEC_TAB[top], "sections: " + ",".join(dict.fromkeys(tags))
    if multi and len(real) <= _FULL_TAGS:
        return SECTION_TABS["multichar"], "multichar"
    if _QUOTED.match(t) or _TEXT.search(head[:160]) or (_TEXT.search(head) and len(real) <= _FULL_TAGS):
        return SECTION_TABS["text"], "text"
    if len(_VIDEO.findall(head)) >= 2 and "::" not in head and "||" not in head and not _COUNT.search(head) \
            and "artist" not in head.lower():
        return VIDEO, "video prompt"
    artists = real.count("artist_mix")
    if artists >= 3 and artists >= len(real) * 0.5 and not _COUNT.search(head):
        return SECTION_TABS["artist_mix"], "artist mix"
    if len(real) == 1 and artists == 1 and len(lines) == 1 and not _KEYWORD_RES["clothes"].search(head) \
            and not re.search(r'["=/\\]', head):
        return SECTION_TABS["artist"], "artist name"
    kinds = {x for x in real if x not in ("other", "scene")}
    if len(real) >= _FULL_TAGS and _COUNT.search(head) and len(kinds) >= 3:
        return FULL, f"whole prompt ({len(real)} tags, {len(kinds)} sections)"
    sec = ai.section_of(t)
    if sec == "character" and len(real) > _CHAR_MAX_TAGS:
        sec = ""                        # a name buried in a longer snippet is not a character clip
    if not sec and len(real) <= 3 and ("character" in real) and len(lines) <= 2:
        sec = "character"               # "satsuki, blue archive": name + series
    if sec in SECTION_TABS:
        return SECTION_TABS[sec], sec
    if len(real) >= _FULL_TAGS and len(kinds) >= 3:
        return FULL, f"whole prompt ({len(real)} tags, {len(kinds)} sections)"
    tab = _keyword_tab(head)
    if tab:
        return tab, "keywords"
    return OTHER_PROMPTS, "prompt, no single section"


def _keyword_tab(head: str) -> str:
    """Which section the words of an unplaced prompt snippet point at; '' when it is a mix."""
    tags = [x for x in re.split(r"[,\n|]+|::", re.sub(r"-?\d+(?:\.\d+)?::|[{}\[\]]", "", head)) if x.strip()]
    if not tags or len(tags) > 40:
        return ""
    votes = {}
    for tag in tags:
        hits = [k for k, rx in _KEYWORD_RES.items() if rx.search(tag)]
        if len(hits) == 1:
            votes[hits[0]] = votes.get(hits[0], 0) + 1
    if not votes:
        return ""
    best = max(votes, key=votes.get)
    if votes[best] >= max(1, 0.6 * sum(votes.values())) and sum(votes.values()) >= 0.5 * len(tags):
        return best
    return ""


def is_novelai(meta: dict) -> bool:
    """CopyQ source capture: the clip's tags / notes / window title name novelai.net."""
    m = meta or {}
    return bool(re.search(r"novelai", " ".join(str(m.get(k) or "") for k in ("source_title", "source_app", "tags", "notes")), re.I))


def _classify_raw(text: str, meta: dict = None):
    """-> (tab, why). meta: source_app, source_title, direction (all optional)."""
    meta = meta or {}
    if text.count("\\n") >= 2 and "::" in text:      # a prompt copied as an escaped string
        text = text.replace("\\n", "\n")
    hit = not_prompt(text, meta)
    if hit and is_novelai(meta) and hit[0] not in (SEEDS, NAI_FILES) and text.strip():
        hit = None                      # copied on novelai.net: it is a prompt piece, not a note/path/link
    if hit:
        return hit
    if is_novelai(meta) and text.strip():
        return prompt_tab(text.strip(), is_prompt(text.strip())[2])
    t = text.strip()
    yes, why, labels = is_prompt(t)
    if yes:
        return prompt_tab(t, labels)
    head = t[:HEAD]
    lines = _lines(head)
    if _EMOTICON.match(t):
        return SECTION_TABS["face"], "emoticon"
    if len(lines) == 1 and _TITLE_TAIL.search(t) and len(t) <= 120:
        return TITLES, "session title"
    quote = _HAS_QUOTE.search(t)
    if len(lines) == 1 and len(t) <= 160 and quote and len(quote.group(0)) >= 0.6 * len(t):
        return SECTION_TABS["text"], "quoted words"
    if len(_VIDEO.findall(head)) >= 2 and len(head) < 1500 and "||" not in head and "::" not in head:
        return VIDEO, "video prompt"
    items = [x for x in re.split(r"[,\n]+", head) if x.strip()]
    if len(_UC_WORDS.findall(head)) >= max(2, 0.6 * len(items)) and len(items) >= 2 and len(head) < 400 \
            and not _PROSE_END.search(head) and not _TEXT.search(head) and not quote:
        return NEGATIVES, "negative words"
    if len(head) <= 200 and len(lines) <= 3 and not _PROSE_END.search(head):
        tab = _keyword_tab(head)
        if tab:
            return tab, "keywords"
    if len(lines) == 1 and _CHAR_NAME.match(t) and len(t) <= 70:
        return SECTION_TABS["character"], "name (series)"
    if _QUOTED.match(t) or (_TEXT.search(head) and len(head) < 600):
        return SECTION_TABS["text"], "text"
    return NOTES, "not a prompt (" + why + ")"


# ---- character gate (2026-10-15) ------------------------------------------------------------
# Only real characters may land in "characters": every piece of the clip must be a name from the
# Danbooru character lists, extra_characters.json (live Danbooru checks) or mywaifulist, or a
# series / style word. Anything else falls through to the keyword tab, other prompts or notes.
_SCRIPTS = r"C:\Users\Zoro_\Documents local backup of HDD\00000 python scripts"
_CHAR_SOURCES = {
    "danbooru_txt": _SCRIPTS + r"\posting automation\prompt db\character_blacklist_merged.txt",
    "danbooru_db": _SCRIPTS + r"\posting automation\novelai director\character_series_gender.sqlite3",
    "extra": _SCRIPTS + r"\posting automation\novelai director\extra_characters.json",
    "waifulist": _SCRIPTS + r"\tampermonkey\mywaifulist_waifus_full.json",
}
_STYLE_OK = {"official art", "official style", "official clothes", "canon", "anime", "game cg", "cosplay"}
_CHARS = None


def _cnorm(s: str) -> str:
    return re.sub(r"\s+", " ", s.replace("_", " ").replace("\\", "").strip().lower())


def _load_chars():
    """-> (names, series), loaded once and kept for the life of the process."""
    global _CHARS
    if _CHARS is not None:
        return _CHARS
    import json, os, sqlite3
    names, series = set(), set()

    def add(n):
        n = _cnorm(n)
        if not n:
            return
        names.add(n)
        m = re.match(r"^(.*?) \((.+)\)$", n)
        if m:
            if len(m.group(1)) >= 4:
                names.add(m.group(1))
            series.add(m.group(2))
    src = _CHAR_SOURCES
    if os.path.exists(src["danbooru_txt"]):
        for ln in open(src["danbooru_txt"], encoding="utf-8", errors="replace"):
            add(ln)
    if os.path.exists(src["danbooru_db"]):
        con = sqlite3.connect(src["danbooru_db"])
        for tag, ser in con.execute("select tag, series from characters"):
            add(tag)
            if ser:
                series.add(_cnorm(ser))
        con.close()
    if os.path.exists(src["extra"]):
        for k, v in json.load(open(src["extra"], encoding="utf-8")).items():
            if v:
                add(k)
    if os.path.exists(src["waifulist"]):
        for it in json.load(open(src["waifulist"], encoding="utf-8")).get("items", []):
            add(it.get("name") or "")
            if it.get("series"):
                series.add(_cnorm(it["series"]))
    series.discard("")
    _CHARS = (names, series)
    return _CHARS


def _is_name(piece: str, names: set) -> bool:
    """Known character, also with costume/series parens peeled or the two name parts swapped."""
    while True:
        if piece in names:
            return True
        w = piece.split(" ")
        if len(w) == 2 and f"{w[1]} {w[0]}" in names:      # yoruichi shihouin / shihouin yoruichi
            return True
        m = re.match(r"^(.*?) \([^()]+\)$", piece)
        if not m:
            return False
        piece = m.group(1)


def is_character_clip(text: str) -> bool:
    """True when the clip is only character name(s) plus series / style words."""
    names, series = _load_chars()
    body = re.sub(r"-?\d+(?:\.\d+)?::|::|[{}\[\]|]|[\x00-\x08\x0b-\x1f]", ",", text[:HEAD])
    found = False
    for piece in re.split(r"[,\n]+", body):
        piece = _cnorm(piece)
        if not piece or piece in _STYLE_OK or piece in series:
            continue
        m = re.match(r"^(.*?) \(([^()]+)\)$", piece)
        if _is_name(piece, names):
            found = True
            continue
        if piece.endswith(" (series)") or (m and m.group(2) in series):
            continue
        return False                    # an unknown word: not a pure character clip
    return found


_RAND_BLOCK = re.compile(r"^\|\|.*\|\|,?$")
_BLOCK_ORDER = ("pose", "sex_acts", "clothes", "body", "face", "multichar")


def randomizer_sections(text: str) -> list:
    """A clip made only of ||a|b|c|| randomizer lines -> the section of each line (majority label),
    in _BLOCK_ORDER. [] when the clip is not randomizer-only or a line has no clear section."""
    lines = [x.strip() for x in text.strip().split("\n") if x.strip()]
    if not lines or not all(_RAND_BLOCK.match(x) for x in lines):
        return []
    secs = set()
    for x in lines:
        labels = [y for y in is_prompt(x)[2] if y not in ("other", "count", "quality", "negative")]
        if not labels:
            continue
        top = max(set(labels), key=labels.count)
        if labels.count(top) < 0.5 * len(labels):
            return []
        secs.add(top)
    return [k for k in _BLOCK_ORDER if k in secs]


def classify(text: str, meta: dict = None):
    """-> (tab, why). meta: source_app, source_title, direction (all optional).
    Randomizer-only clips: why = 'randomizer: <sec>,<sec>' (all block sections, used as tags)."""
    secs = randomizer_sections(text)
    if secs and secs[0] in SECTION_TABS:
        return SECTION_TABS[secs[0]], "randomizer: " + ",".join(secs)
    tab, why = _classify_raw(text, meta)
    if tab != SECTION_TABS["character"] or is_character_clip(text):
        return tab, why
    kw = _keyword_tab(text.strip()[:HEAD])
    if kw and kw != SECTION_TABS["character"]:
        return kw, "keywords (not a known character)"
    if is_prompt(text.strip())[0]:
        return OTHER_PROMPTS, "not a known character"
    return NOTES, "not a known character"