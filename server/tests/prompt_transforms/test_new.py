"""The transforms with no userscript counterpart, plus apply()'s selection rules."""
import sys
sys.path.insert(0, r"C:\Users\Zoro_\Documents local backup of HDD\00000 python scripts\clipboard_sync")
import prompt_transforms as pt

CASES = [
    # multichar prefixes, per tag, separators preserved
    ("prefixSource", "ass grab, kissing", "source#ass grab, source#kissing"),
    ("prefixTarget", "ass grab, kissing", "target#ass grab, target#kissing"),
    ("prefixMutual", "kissing", "mutual#kissing"),
    ("prefixSource", "ass grab\nkissing", "source#ass grab\nsource#kissing"),
    # existing prefix is replaced, not stacked
    ("prefixSource", "target#ass grab", "source#ass grab"),
    ("prefixTarget", "source#ass grab, kissing", "target#ass grab, target#kissing"),
    # the prefix goes on the tag, inside the weight wrapper
    ("prefixSource", "1.2::ass grab::", "1.2::source#ass grab::"),
    ("prefixSource", "1.2::ass grab::, kissing", "1.2::source#ass grab::, source#kissing"),
    ("prefixTarget", "-2::bad hands::", "-2::target#bad hands::"),
    # swap only touches source/target, leaves mutual and bare tags alone
    ("swapSourceTarget", "source#ass grab, target#ass smack, kissing",
     "target#ass grab, source#ass smack, kissing"),
    ("swapSourceTarget", "mutual#kissing", "mutual#kissing"),
    ("swapSourceTarget", "1.2::source#ass grab::", "1.2::target#ass grab::"),
    # strip
    ("stripPrefix", "source#ass grab, target#kissing, solo", "ass grab, kissing, solo"),
    ("stripPrefix", "SOURCE#ass grab", "ass grab"),
    ("stripPrefix", "1.2::source#ass grab::", "1.2::ass grab::"),
    # case insensitive input, canonical lowercase output
    ("prefixSource", "Source#ass grab", "source#ass grab"),
    # empty and whitespace survive untouched
    ("prefixSource", "", ""),
    ("stripPrefix", "", ""),
    ("prefixSource", "a, , b", "source#a, , source#b"),
    # dedupe keeps first occurrence and order, case insensitive
    ("dedupeTags", "1girl, solo, 1girl, SOLO, smile", "1girl, solo, smile"),
    ("dedupeTags", "1girl\nsolo\n1girl", "1girl, solo"),
    ("dedupeTags", "0.5::wlop::, 0.5::wlop::", "0.5::wlop::"),
    # weight stepper
    ("weightUp", "wlop", "1.1::wlop::"),
    ("weightDown", "wlop", "0.9::wlop::"),
    ("weightUp", "0.5::wlop::", "0.6::wlop::"),
    ("weightDown", "0.5::wlop::", "0.4::wlop::"),
    ("weightDown", "0.1::wlop::", "0.0::wlop::"),
    ("weightUp", "-2::bad hands::", "-1.9::bad hands::"),
    ("weightUp", "1.0::rating 5::", "1.1::rating 5,::"),   # trailing digit guarded
    ("weightUp", "", ""),
    ("weightUp", "   ", "   "),
]

fails = []
for tid, src, want in CASES:
    got = pt.apply(tid, src)["text"]
    if got != want:
        fails.append((tid, src, want, got))

# ---- apply() mechanics ----
mech = []

def check(label, cond, detail=""):
    if not cond:
        mech.append(f"{label}: {detail}")

# no selection = whole text
r = pt.apply("wrapOnly", "abc")
check("whole text", r["text"] == "||abc||", r["text"])
check("caret spans result", (r["start"], r["end"]) == (0, 7), (r["start"], r["end"]))

# selection = only that substring, caret lands on the replacement
r = pt.apply("wrapOnly", "1girl, solo, smile", 7, 11)
check("selection only", r["text"] == "1girl, ||solo||, smile", r["text"])
check("selection caret", (r["start"], r["end"]) == (7, 15), (r["start"], r["end"]))
check("selection text", "1girl, ||solo||, smile"[r["start"]:r["end"]] == "||solo||")

# reversed selection is accepted
r = pt.apply("wrapOnly", "1girl, solo, smile", 11, 7)
check("reversed selection", r["text"] == "1girl, ||solo||, smile", r["text"])

# out of range is clamped, not an error
r = pt.apply("wrapOnly", "abc", -5, 999)
check("clamped", r["text"] == "||abc||", r["text"])

# changed flag
check("changed true", pt.apply("wrapOnly", "abc")["changed"])
check("changed false", not pt.apply("braceUnwrap", "abc")["changed"])
check("move at top is a no-op", not pt.apply("moveUp", "a\nb", 0, 0)["changed"])

# a document transform never slices by the selection
r = pt.apply("moveDown", "a\nb\nc", 0, 0)
check("moveDown whole doc", r["text"] == "b\na\nc", r["text"])

# errors
for bad, kind in (("nope", "unknown"), (None, "none")):
    try:
        pt.apply(bad if kind == "unknown" else "wrapOnly",
                 "x" if kind == "unknown" else None)
        mech.append(f"{kind}: no error raised")
    except pt.TransformError:
        pass
try:
    pt.apply("wrapOnly", "x" * (pt.MAX_CHARS + 1))
    mech.append("too long: no error raised")
except pt.TransformError:
    pass

# non-ascii is not mangled
r = pt.apply("prefixSource", "\u521d\u97f3\u30df\u30af, smile")
check("non ascii", r["text"] == "source#\u521d\u97f3\u30df\u30af, source#smile", r["text"])

# registry is complete and ids are unique
reg = pt.registry()
ids = [x["id"] for x in reg]
check("registry size", len(reg) == len(pt.TRANSFORMS), len(reg))
check("unique ids", len(set(ids)) == len(ids))
check("every id applies", all(pt.apply(i, "1girl, solo") for i in ids))

print(f"{len(CASES)} new-transform cases, {len(fails)} mismatches")
for tid, src, want, got in fails:
    print(f"\n[{tid}] {src!r}\n  want: {want!r}\n  got:  {got!r}")
print(f"apply() mechanics: {len(mech)} failures")
for m in mech:
    print("  " + m)
sys.exit(1 if (fails or mech) else 0)
