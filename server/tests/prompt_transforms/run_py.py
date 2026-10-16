"""Compare prompt_transforms.py against the real userscript JS output."""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = r"C:\Users\Zoro_\Documents local backup of HDD\00000 python scripts\clipboard_sync"
sys.path.insert(0, SRC)

import prompt_transforms as pt  # noqa: E402

fixtures = json.load(open(os.path.join(HERE, "fixtures.json"), encoding="utf-8"))

js_raw = subprocess.run(["node", os.path.join(HERE, "run_js.js")],
                        capture_output=True, text=True, encoding="utf-8")
if js_raw.returncode != 0:
    print("node failed:", js_raw.stderr)
    sys.exit(1)
js = json.loads(js_raw.stdout)

SEL_IDS = ["weight1", "weight05", "neg2", "braceWrap", "braceUnwrap", "pipesWrap",
           "wrapOnly", "joinRandBlocks", "fixRandFormat", "unwrapPipes",
           "mixWithComma", "commaToNL", "nlToComma", "insertCommas",
           "stripLinebreaks", "collapseNL1", "dupeSel"]

fails = []
checked = 0
for fx in fixtures:
    text = fx["text"]
    for tid in SEL_IDS:
        got = pt.apply(tid, text)["text"]
        want = js[f"{fx['name']}||{tid}"]
        checked += 1
        if got != want:
            fails.append((fx["name"], tid, want, got))
    nl = (text.find("\n") + 1) or 0
    for direction, pid in (("up", "moveUp"), ("down", "moveDown")):
        for tag, ss, se in (("caret0", 0, 0), ("line2", min(len(text), nl), min(len(text), nl)),
                            ("all", 0, len(text))):
            want = js[f"{fx['name']}||move_{direction}_{tag}"]
            r = pt.apply(pid, text, ss, se)
            checked += 1
            if want is None:
                if r["changed"]:
                    fails.append((fx["name"], f"{pid}/{tag}", "no move", r["text"]))
            else:
                got = [r["text"], r["start"], r["end"]]
                if got != want:
                    fails.append((fx["name"], f"{pid}/{tag}", want, got))

print(f"{checked} parity cases, {len(fails)} mismatches")
for name, tid, want, got in fails[:25]:
    print(f"\n[{name}] {tid}\n  js: {want!r}\n  py: {got!r}")
sys.exit(1 if fails else 0)
