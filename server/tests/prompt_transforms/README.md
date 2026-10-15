# prompt_transforms tests

`prompt_transforms.py` is a hand port of the transforms in
`tampermonkey\NAI Prompt Tools - Prompt edit Hotkeys (v2.3.0)-backup.user.js`.
The userscript keeps its own JS copy on purpose, so these tests are the only
thing keeping the two honest. Re-run them after touching either side.

| file | what it does |
|---|---|
| `js_transforms_extracted.js` | the userscript's `normalizeWeights` + `T` + `moveLinesCore`, extracted verbatim (lines 215-330 and 360-432) with a `module.exports` added |
| `run_js.js` | runs those real JS transforms over `fixtures.json`, prints JSON |
| `run_py.py` | runs the Python port over the same fixtures and diffs against the JS (644 comparisons) |
| `test_new.py` | the transforms with no JS counterpart (source#/target#/mutual#, swap, strip, dedupe, weight stepper) plus `apply()`'s selection, clamping and error rules |
| `test_endpoints.py` | `GET /transforms`, `POST /transform`, `POST /clip/push` and link forwarding, on an ephemeral port with the clipboard setter, the clip store and the capture server all stubbed |
| `measure.py` | 600 live requests, prints handle count / working set / thread count before and after |

Run all of them (nothing here touches the live server, the real clipboard or
the real browsing history database):

    python run_py.py && python test_new.py && python test_endpoints.py && python measure.py

If the userscript changes, re-extract:

    sed -n '215,330p;360,432p' "<the userscript>" > js_transforms_extracted.js
    echo "module.exports = { T, moveLinesCore, normalizeWeights };" >> js_transforms_extracted.js

Notes
- Tests bind port 0 and read the port back: Windows refuses `bind()` on some
  free-looking ports (8791 gives WinError 10013).
- `/clip/push` with `copy: true` writes the real Windows clipboard, so
  `set_windows_clipboard` is always stubbed in tests.
