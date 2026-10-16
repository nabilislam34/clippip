# ClipPiP handoff (2026-10-15)

## 2026-10-15 (late): pin button, search scope toggle, chunk + body weights tabs (branch `clips-ui-rework`, PR #10, commit da68799)

- State: CI run 38839457458 green (build + simulator tests). IPA = that run's `ClipPiP.ipa` artifact. NOT phone-tested; phone was still on an older build (no Select button), so 1.9 multi-select is also untested there.
- App:
  - Edit prompt sheet: visible "Pin transforms to the clip menu" button = pin mode; tap a transform to pin/unpin (the old hidden long-press did not work in the scrolling chip row). Pinned ones show as "Copy as <label>" in the long-press menu.
  - Library: arrow under the search bar toggles "Searching this tab" / "Searching all tabs" (`LibraryModel.globalSearch`, sends server tab `*` when a query is set). Covers issue #11. `*` = all CopyQ tabs only (not phone history, Ditto or chunks).
- Server (`clipboard_sync\clippip_store.py`, mirrored in `ios_pip_app\server\`):
  - Read-only chunk tabs from `00000 ditto clips database\Prompt clips database
ai_prompt_chunks.json`: parent `chunks` + `chunks:<group>` labelled "chunk <group>" (12 groups, 1002 chunks). Key `k<group>#<i>`, name = chunk label, text = expansion. No rename/delete.
  - Ditto group 35697 "body weights, presets" added to `clippip_config.json` `ditto_groups` (340 clips; Ditto QuickPasteText already becomes tags).
  - Verified over HTTP on the live server (port 5051). Restarted via task `ClipboardSyncServer`, last PID 41476.
  - Pitfall: edit the LIVE `clipboard_sync\clippip_store.py`, not only the `ios_pip_app\server` copy.
- Open: phone test (pin button, search toggle, Select, chunk tabs); kanban item "context menu to add a clip as a chunk" (chunk server 3747) not built; issues #6, #5, #2, #1.

## 2026-10-15: UI rework done, issues #8/#9, multi-select, menu transforms, native exclusions (branch `clips-ui-rework`, 1.9, PR #10)

- State: PR #10 (base main) NOT merged. CI run 38815701941 green, 50 simulator tests. IPA `ios apps\ClipPiP\ClipPiP_1.9.ipa`. NOT tested on the phone (phone still on 1.5).
- App:
  - 3 tabs Clips / Library / Settings, card feed (`ClipCard`), PiP pill above all tabs (`PiPPill`), `Sources\RelativeTime.swift` age badges.
  - #8: Library lists pinned clips first in every tab (`TabOrder.pinnedFirst`).
  - #9: Library sidebar drag a tab onto a tab = reorder (UserDefaults `libTabOrder`, `TabOrder.apply/move`); drag a clip onto a tab = `POST /lib/file` (history clip -> `history:ai:<tab>` moves it; any clip -> CopyQ tab adds a copy; Ditto/fixed views refuse).
  - Find-tab box at the top of the sidebar (`TabOrder.matches`).
  - Multi-select: Select button in Clips and Library; bar = Copy (one per line), Randomizer (`ClipBatch.randomizer`: `||a, b|c||`, one option per clip), Pin.
  - Transforms pinned to the long-press menu: Edit prompt sheet > hold a transform > Pin to clip menu (`MenuTransformStore`, UserDefaults `menuTransforms`, max 12); menu shows "Copy as <label>" (`QuickTransform.run` in Library.swift).
  - Exclusions are native in Settings (`Sources\Exclusions.swift`, same `/pc/exclude` + `/pc/block` routes); browser page link kept.
  - Search: `today`, `yesterday`, `2026-10-15`, `2026-10`, `10-15`, `10/15`, `app:chrome` (Clips tab `ClipSearch`, Library history via server).
  - New pure files compiled into the test target: `TabOrder.swift`, `ClipBatch.swift`, `RelativeTime.swift`.
- Server (`clipboard_sync\`):
  - `clippip_store.lib_file` + route `/lib/file`; `_date_term` / `app:` search in `history_items`.
  - Exclusion toggles `commands` and `searches` (reuse `clippip_rules.not_prompt`), default off.
  - `clippip_rules.py`: NAI file-name check now BEFORE the path check (a path ending `s-<digits>.png` / `s-<digits>_<hash>` -> `nai file names`).
  - TOKEN now read from untracked `clippip_secrets.json` ({"token": ...}), env `CLIPPIP_TOKEN` fallback.
  - Restarted via task `ClipboardSyncServer`, last PID 51236.
- GitHub: the server code is mirrored into the PUBLIC app repo at `ios_pip_app\server\` (copy the changed .py there and push with the app; never commit tokens/IPs). The two `clippip-server` repos made by mistake are archived. ShadowXebec12 = NAI/tampermonkey/mix gallery; nabilislam34 = school, ClipPiP is the one exception.
- Open: phone test of 1.9; old phone clips misfiled as `file paths` before the rules fix (#1203-1227) not re-sorted; issues #6 (source lookup), #5/#2 (keyboard), #1 (latency).

## Start here

Two jobs are owed for the next chat, in this order. Neither was done on 2026-10-12.

1. **The keyboard is STILL NOT FIXED on the phone** (the user's main bug). Known so far:
   - User's report: listed in Settings > Keyboards, but never appears / jumps back to the normal keyboard.
   - The code is fine on iOS 26: CI job `keyboard-launch` (run 38295328882) launches the real extension in an
     iOS 26.2 simulator and the screenshot shows it drawn. Do not rewrite the layout again.
   - The phone has **1.5** (Sideloadly `%LOCALAPPDATA%\Sideloadly\installations.db`, plugins kept), iOS 26,
     a free Apple ID, and a second signing tool (plumesign, for LiveContainer) was used on the same ID.
   - Not tried yet: reinstall 1.7 with Sideloadly, remove + re-add the keyboard, Allow Full Access.
   - If that fails, get the crash log: phone on USB, `pymobiledevice3 crash pull <dir>` (install it in a venv),
     look for `ClipPiPKeyboard*.ips`. Fix from the log, not from a guess.
2. **The UI rework was NOT done**: the 3 tab split (Clips / Library / Settings) and the card feed. The agreed
   design is under "Agreed UI design" below; do not re-brainstorm it. Pins exist now (`Sources\Pins.swift`) but
   as a plain list section, not the horizontal strip from the design.

Also unconfirmed on the phone: everything in 1.6 and 1.7 (transform sheet, pins, the new source app lookup).
After sideloading 1.7 and copying in Reddit, read `origin_probe.log` in this folder.

- Cut new work from branch `clip-pins-origin` (1.7, PR #7, based on `clip-transform-sheet` / PR #3). Add the
  new branch name to `.github\workflows\build-ios.yml` or CI does not run.
- Newest IPA: `ios apps\ClipPiP\ClipPiP_1.7.ipa` (built before the `-focusSearch` launch argument and the
  `keyboard-launch` CI job were added; those only matter to CI).
- The local AI model is off for good (next section). Do not use Ollama on this laptop.
- Read this file, then the wiki note `C:\Users\Zoro_\Obsidian Remote copy of D drive 1\00 Other LLMS\0 Claude conversations\0 claude code sessions\wiki\10. Clipboard\ClipPiP iOS App & Laptop Clip Store.md` (full history), then the top entries of `C:\Users\Zoro_\.claude\projects\C--Users-Zoro-\memory\recent_work_log.md`.
- Kanban for this project: Obsidian `Project Kanbans\Ditto & CopyQ.md` (three open cards for this work).

## 2026-10-12 (later): the AI model is OFF, sorting is rules only

- The user scrapped the local model (it filled the 6 GB card and crashed Brave). `clippip_ai.py` has
  `USE_LLM = False`; `decide()` now only calls `clippip_rules.classify(text, meta)`. Do not turn it back on.
- NEW `clippip_rules.py`: built from a survey of all 82 CopyQ tabs and 73 Ditto groups. First match wins:
  seeds, setup strings, lora urns / trigger words, links, terminal and logs, everything searches, file paths,
  nai file names, hashes and tokens, session titles, commands and code, then the prompt gate (negatives (uc),
  multichar, text and dialogue, video prompts, artist mixes, artists, full prompts, the gallery sectioner,
  a keyword vote for faces / body / clothes / sex acts / backgrounds, other prompts), else notes and other.
- `meta` = the clip's `source_app` / `source_title`: a clip equal to the terminal window title is a session title.
- Score against the user's own tabs: 1387 of 1640 (84.6%), about 4 ms a clip; most misses are tabs that are
  mixed themselves (male uc, cmds, Nai prompts, wan). On the 267 stored clips about 2 are wrong.
- DB copy before the relabel: `backup\clippip_clips_20261012_before_rules_relabel.sqlite`; organizer backup
  `backup\clippip_ai_20261012_before_rules_only.py`. The real CopyQ inbox tabs are still not touched.
- **Keyboard**: new CI job `keyboard-launch` installs the real app in the iOS 26.2 simulator, enables the
  keyboard and screenshots it. Run 38295328882: the extension launches and draws (chips, toolbar, the Full
  Access hint). So the keyboard code is fine on iOS 26; the phone failure is specific to the device install
  (signing / Sideloadly / the phone still on 1.5). Still needs the phone's crash log over USB.

## 2026-10-12: prompt gate for the AI organizer, pins, real source lookup (branch `clip-pins-origin`, 1.7)

- **Tested which is better on prompt snippets** (285 clips: 35 per section from the user's own sorted
  CopyQ + Ditto tabs, plus 40 non-prompt phone clips; scratch `bench.py`, not kept): the prompt sectioner
  is right on 88% of what it answers (172 of 196), the local model on 75% (148 of 198). The model is worst on
  artists (calls them characters) and sex acts (23%). So:
- `clippip_ai.py` (backup `backup\clippip_ai_20261012_before_prompt_gate.py`) now routes in this order:
  junk rules -> link-only clip = `links` -> shell command rule (`_CMD_RE`) = `commands and code` ->
  `is_prompt()` gate. A prompt snippet goes to `clip_section` ONLY (no section = `other prompts`); the
  model never picks a prompt section any more. Everything else goes to the model, which may only answer
  note / prompt / junk (`notes and other` / `other prompts` / `trash review`).
- `is_prompt()` = prompt syntax (`1.3::`, `artist:`, `source#`, `||a|b||`, `{{..}}`, `1girl`) or at least
  half the tags known to `prompt_sections` (a "tag" over 5 words never counts). 239 of 245 labelled prompt
  clips pass; of the 256 stored clips only real prompts pass. Misses: OC names the vocab does not know.
- The model's cache key is now `v4:` + sha (old verdicts are ignored). All 256 stored labels were cleared
  and redone (db copy `backup\clippip_clips_20261012_before_prompt_gate_relabel.sqlite`).
- Known sectioner limits, untouched: the user's `body weights` and `sex acts` tabs mix poses, framing and
  body blocks, so those two score low for both methods; `satsuki, blue archive` (name + series) gets no section.
- **Source app, why it never worked**: `_UIConcretePasteboard` has no item collection getter or ivar (checked
  in the iOS 17 and 18.2 runtime headers); the collection lives in a C cache. 1.5's getters could not match.
  1.7 asks `[[PBServerConnection defaultConnection] pasteboardWithName:@"com.apple.UIKit.pboard.general" error:]`
  and reads `originatorBundleID` / `originatorLocalizedName` off the returned `PBItemCollection` (both are
  encoded across XPC as `bundleIdentifier` / `localizedName`). Unknown until the phone test: whether iOS 26
  hands the bundle id to a third party app.
- The server now also appends every `X-Clip-Probe` to `origin_probe.log` (stdout is block buffered, so the
  `[origin-probe]` lines of 1.5 were never on disk). The server log itself is still buffered.
- Shortcuts route (public, works for every app): iOS 18.2+ has a **Get Current App** action, so ONE
  automation (App > pick the apps > Is Opened > Run Immediately: Get Current App -> Set Current App) covers
  all of them. The phone is on iOS 26.
- **Pins**: `Sources\Pins.swift` (`PinStore`, UserDefaults, cap 100), Pin / Unpin in the long press menu
  in Clips and Library, a Pinned section at the top of Clips. Phone only: the keyboard does not show pins.
- **Keyboard, still open**: Sideloadly's `installations.db` says the phone has 1.5 with plugins kept
  (`drop_plugins` 0). The user reports: listed in Settings, but never appears / jumps back to the normal
  keyboard. The appex in the IPA is well formed (plist, `_NSExtensionMain`, principal class). No crash log
  on the laptop is newer than 2026-10-10 08:51. Next step is a crash log from the phone (USB,
  `pymobiledevice3 crash pull`), not another guess.
- Seen, not fixed: 36 of 102 phone `POST /set` calls answered 500 (the PowerShell `Set-Clipboard` call
  fails, the clip is still stored).

## What ClipPiP is

- An iOS app (sideloaded, unsigned build) that keeps running in the background through Picture in Picture and syncs the clipboard both ways with a Python server on the Windows laptop.
- It also browses the laptop's clip history and CopyQ tabs (the "Library"), edits prompt clips through the PC's transforms, and has a custom keyboard extension that searches and types clips.
- Laptop server: `clipboard_sync_server.py` on port 5051, scheduled task `ClipboardSyncServer`, started hidden. Every request carries `?token=<token>`.
- Clip store: `C:\Users\Zoro_\Documents local backup of HDD\00000 ditto clips database\clipPip ios clips\clippip_clips.sqlite` (table `clips`), one file per clip under `clips\ios\YYYY-MM\` and `clips\pc\YYYY-MM\`, thumbnails in `thumbs\`.

## Where everything lives

- Server folder: `C:\Users\Zoro_\Documents local backup of HDD\00000 python scripts\clipboard_sync\`
  - `clipboard_sync_server.py`: HTTP routes. The exclusions settings page is the `EXCLUDE_PAGE` HTML string in this file.
  - `clippip_store.py`: clipboard reads, clip store, CopyQ tab cache, source detection (`ios_source`), exclusions (`exclude_reason`), tabs (`lib_tabs`).
  - `prompt_transforms.py` (2026-10-11): 27 pure text transforms + the registry the phone renders. See "Prompt transforms" below.
  - `clippip_links.py` (2026-10-11): links copied on the phone go to the local browsing history server.
  - `clippip_config.json`: CopyQ tab list, `pc_to_phone_enabled`, `blocked_sources`, `exclude`, `link_capture`.
  - `clippip_ai.py`: local AI clip organizer (scheduled task `ClipPiPAIOrganizer`, every 10 minutes, phone history only).
  - `tests\prompt_transforms\`: the node-vs-python parity test and the endpoint tests. Read its `README.md`.
  - `backup\`: dated copies made before each edit.
- App repo: `clipboard_sync\ios_pip_app\` (git, remote https://github.com/nabilislam34/clippip , PUBLIC, the user's school account).
  - `Sources\ClipPiPApp.swift` (main SwiftUI screens, `RootView`, `ContentView`, `EditedText`).
  - `Sources\Library.swift` (Library tab, `ClipRow`, `ClipMenu`, `FullClipSheet`, `RenameSheet`, `LibraryView`).
  - `Sources\TransformSheet.swift` (the prompt edit sheet, `TransformModel`, `SelectableTextEditor`).
  - `Sources\PromptSelection.swift` (pure `line()` / `tag()` selection helpers + `TransformFavourites`; this file is also compiled into the test target).
  - `Sources\ClipMonitor.swift` (sync logic, `fetch`, `post`, `postJSON`), `Sources\ClipOrigin.swift`, `Sources\Intents.swift`, `Sources\PiPManager.swift`, `Sources\VideoMaker.swift`.
  - `Keyboard\KeyboardViewController.swift` (keyboard extension, UIKit).
  - `Tests\KeyboardLayoutTests.swift`, `Tests\ClipOriginTests.swift`, `Tests\PromptSelectionTests.swift`.
  - `project.yml` (XcodeGen, version 1.6), `.github\workflows\build-ios.yml`, `README.md`.
- Built IPAs: `C:\Users\Zoro_\Documents local backup of HDD\ios apps\ClipPiP\` (`ClipPiP_1.6.ipa` is the newest).

## Current state

- Branches (nothing is merged to main yet, so cut new work from `clip-transform-sheet`):
  - `main` (1.3).
  - `local-ai-organizer` (1.4: long poll + keyboard redesign). Pushed, NOT merged.
  - `clip-source-app` (1.5, cut from `local-ai-organizer`). Pushed, NOT merged, no pull request.
  - `clip-transform-sheet` (1.6, cut from `clip-source-app`). Pushed, **pull request #3 open**, NOT merged. Commits `edb881e`, `58a216e`, `e58a331`.
- CI run 38199161302: build + test both green, 24 simulator tests, 0 failures.
- **Nothing from 1.4, 1.5 or 1.6 has been tested on the phone.** Including whether the keyboard shows at all.
- Server side is live and verified. The PID after the last restart was 66624. Always look the PID up again.
- Features already in, server side live: the clip store, Library tabs, source app detection, exclusions, the AI organizer, the prompt transforms, link capture.

## Prompt transforms (2026-10-11, the feature just built)

- `prompt_transforms.py` is a hand port of the transforms in `tampermonkey\NAI Prompt Tools - Prompt edit Hotkeys (v2.3.0)-backup.user.js`. The userscript keeps its own JS copy ON PURPOSE (the user chose that); the only thing keeping the two honest is the parity test.
- 27 transforms in 5 groups: weights (`1.0::`, `0.5::`, `-2::`, +/-0.1 stepper, braces), randomizers (`pipesWrap`, `wrapOnly`, join, fix, unwrap, mix with comma), separators (comma <-> newlines, insert commas, strip linebreaks, collapse, duplicate, dedupe), multichar (`source#` / `target#` / `mutual#` prepend per tag, swap, strip) and lines (move up/down).
- `apply(action, text, start, end)` -> `{text, start, end, changed}`. A selection transform sees only the selected substring; **no selection means the whole text**, same as the userscript. `moveUp`/`moveDown` are "document" scope: they take the caret, not a slice.
- Multichar prefixes are new: nothing in the tampermonkey folder did this. The prefix goes INSIDE a weight wrapper (`1.2::source#ass grab::`), replaces an existing prefix instead of stacking, and is applied per tag with the original separators untouched.
- Routes:
  - `GET /transforms` -> `{transforms: [{id, label, group, group_label, scope}], groups: {...}}`. The app renders the sheet from this, so **a new transform in Python needs no app rebuild**.
  - `POST /transform` `{action, text, start?, end?}` -> the result above. Pure: nothing stored, no clipboard touched.
  - `POST /clip/push` `{text, copy, save}` -> commits. `copy` sets the PC clipboard through the existing echo guard, `save` stores a new clip.
- App side: long press a text clip > "Edit prompt". `onTransform` is an OPTIONAL extra action on `ClipMenu` / `ClipRow`; image clips do not get it. Raw monospace `UITextView` (SwiftUI's `TextEditor` cannot report or set a selected range, hence `SelectableTextEditor`). Line / Tag / All selection buttons, Undo stack capped at 40, Reset, Copy / Save.
- Verified: 644 parity comparisons running the REAL userscript JS in node against the Python port, 0 mismatches; 31 new-transform cases; endpoint tests on an ephemeral port; 600 live requests with handles 199 -> 199 and working set 33 -> 34 MB.
- Re-run after touching EITHER copy: `cd tests\prompt_transforms && python run_py.py && python test_new.py && python test_endpoints.py && python measure.py`.

## Link capture (2026-10-11)

- Every http(s) url in a phone text clip is POSTed to the local browsing history server, which owns its own SQLite. ClipPiP never writes that database directly.
- `clippip_links.py`: ONE worker thread (not one per clip), queue capped at 50, dedupe cache capped at 400 urls / 60 minutes, 3 s timeout, every failure swallowed and logged. The title is taken from the line above the url ("Some Post Title\nhttps://...").
- Config `link_capture` in `clippip_config.json`: `enabled`, `endpoint` (`http://127.0.0.1:8770/capture`), `timeout`, `ios_only` (true = PC clips are not forwarded), `max_per_clip`, `dedupe_minutes`.
- The browsing history project is at `00000 python scripts\local browsing history` (`run_server.py`, port 8770, db `browsing_history.sqlite3`). Its own privacy policy already drops login, payment and medical urls, so ClipPiP does not filter again.
- **NOT verified end to end.** It was only proven against a fake capture server; no test rows were written into the real `browsing_history.sqlite3`. To confirm: copy a link on the phone, then look for a new row and a `[link] captured ...` line in the server log.

## Tab tree, 26 more CopyQ tabs, and the Ditto groups (2026-10-11)

- `copyq_tabs` in `clippip_config.json` (and the matching `DEFAULT_CONFIG` in `clippip_store.py`) went
  from 9 to 35 entries. New: the mixes subtabs (`new mixes`, `v5 mixes`, `others mixes`, `v3 mixes`), the
  whole `pr&ompt presets` group (14 tabs, including `uc/male uc` and `uc/female uc`) and the whole
  `2 clipboar&d/test` group (`test 2`, `todd prompts` + its `uc`, `girl text`, `shota` + `uc` + `dialogue`).
  Tab names are the exact CopyQ names with their `&` accelerators and their literal backslashes; take them
  from `copyq tab`, never retype them. In that output the nesting separator is `/`, so a backslash inside a
  segment is part of the name.
- Each entry can now carry `"parent"` = the parent tab's exact name. `/lib/tabs` passes it through, so the
  phone draws a tree. `copyq tab` output is NOT tree order; children are ordered by hand in the config.
- NEW `ditto_groups` in the config plus a read-only Ditto reader in `clippip_store.py` (`ditto_groups`,
  `_ditto_db`, `_ditto_fetch`, `_ditto_group_items`, `_ditto_items`):
  - Tab ids are `ditto:<Main.lID>`, item keys `d<group id>#<clip id>`. Groups configured: artists 3553,
    faces 5010, clothes 394, mixes 6283 (+ v3 mixes 39215), characters 372 (+ fate 5013, marvel 5898,
    request characters 33786). `"parent"` here is the parent group's id.
  - The DB path comes from registry `HKCU\Software\Ditto` -> `DBPath3` every hour, never hardcoded. It is
    opened `mode=ro` and NOTHING here ever writes to Ditto; `lib_rename` / `lib_delete` raise
    "the Ditto library is read only" for a `d...` key, and `_tab_names` refuses a ditto id so one can never
    reach the CopyQ code.
  - `QuickPasteText` becomes the clip's `tags`, so the phone's tag filter and `/lib/tags` work on Ditto
    quick text. `mText` becomes the clip `name`, unless it is just a copy of the clip text.
  - Text clips only: a clip with no `CF_UNICODETEXT` payload (an image / `CF_DIB` clip) is skipped.
  - **Order is Ditto's own, copied from the Ditto source** (`src/MainFrm.cpp` and the `Main_InGroup2`
    index): `stickyClipGroupOrder DESC, clipGroupOrder DESC` (pinned first; `-2147483647` = not pinned).
    Do not "fix" this to ASC and do not trust the export scripts' plain `ORDER BY clipGroupOrder`.
  - The group query is fully indexed (`Main_InGroup2` + `Data_ParentId_Format`), about 4 ms per group on the
    155 GB db. Cache is 300 s per group with a background refresh and a first-open wait loop, the same shape
    as the CopyQ cache. Never read the whole table, never copy the file.
- App side `ios_pip_app\Sources\Library.swift`: `LibTab.parent`, `visibleTabs` / `toggle` /
  `openAncestors`, chevrons and indentation in the sidebar, open groups remembered in `libOpenTabs`,
  sidebar 96 -> 124 pt. The **keyboard extension still lists tabs flat**, so three of them read "uc" and
  two read "v3 mixes" there.
- Verified server side: all 44 tabs return items and tags; ditto faces 359 / characters 938 / mixes 739 /
  clothes 336 / artists 153; quick text appears as tags (sex faces 68, solo faces 14); a two-thread
  first-open race test passes; 200 forced Ditto fetches 4 ms each with handles 139 -> 139; 200 live HTTP
  requests handles 179 -> 179 and 33 -> 35 MB; cold `tab=*` across 35 tabs 3.6 s, warm 4 ms. Live server
  restarted through the task, PID 66624 -> 26216 -> 39212.
- NOT verified: the Swift sidebar (no Swift compiler here). It also did NOT get its own branch - a
  concurrent session committed its transform-sheet work while the edit was in the tree, so the change sits
  inside commit `edb881e` on `clip-transform-sheet`. Pre-change file:
  `ios_pip_app\Sources\backup\Library_20261011_231250_before_nested_tabs.swift`.
- Also noted, untouched: `pr&ompt presets/group sex` is empty; `body wei&ghts/v5 body weights` exists but
  was not asked for; `test_clipboard_sync_server.py` was already broken before this work (it imports
  `parse_request_text`, now `parse_post_text`).

## Agreed UI design (decided with the user, do not re-litigate)

- **3 tabs**: Clips (pure feed, nothing else), Library (the tab tree), Settings (PC server, PC clips toggle, exclusions, keyboard link, version). Today the PC server fields, the keyboard link button and the clip feed all share one `List` in `ContentView` - that split is the main remaining job.
- **PiP control is not a tab**: keep it as a status pill at the top of Clips (tap to start/stop, colour shows state). It already lives above the `TabView` in `RootView`.
- **Card feed** for Clips: rounded card per clip, 2 line monospace preview, a LEFT COLOUR BAR by source (the primary signal, not text), source icon plus a relative time badge ("2m", "3h", "Tue"), 44pt thumbnail for image clips, tap copies with a haptic and a brief toast.
- Pinned clips in a horizontal strip above the feed. Long press menu rather than inline buttons. Dark mode first. No pull to refresh (the long poll already pushes; a refresh control implies it does not work). An empty state that teaches ("Copy something on the PC and it lands here") with the server status inline.
- Later, agreed but not built: a **staging bar** ("3 clips - 180 chars - Copy") so tapping clips appends them into one prompt; "split into fragments" using `clip_section` / `prompt_sections` to offer the pieces as chips; a server-driven action registry for the heavier actions (hash lookup, mix ID, similar prompts, char gen) in three tiers (instant / 0.5-5 s with a spinner / background job with a progress row).
- The user chose: raw text in the sheet (not tag chips), transforms also write back to the PC clipboard, and the userscript JS stays as it is.

## How to build and test

- Swift cannot be compiled on this PC. The only compile and test path is GitHub Actions after a push.
  - The build job makes the unsigned IPA (artifact `ClipPiP-ipa`), the test job runs the simulator tests.
  - The workflow only runs on branches listed in `.github\workflows\build-ios.yml` (`main`, `local-ai-organizer`, `clip-source-app`, `clip-transform-sheet`). Add a new branch name there or nothing runs.
  - Download the IPA with `gh run download <run id> -R nabilislam34/clippip` and copy it to `ios apps\ClipPiP\ClipPiP_<version>.ipa`.
- Push with the school account without switching the active gh account:
  `GH_TOKEN=$(gh auth token -u nabilislam34)` then `git -c http.extraheader="Authorization: Basic $(printf "x-access-token:%s" "$GH_TOKEN" | base64 -w0)" push`.
  The active gh account is ShadowXebec12 and must stay active. Commits in this repo carry no Claude attribution beyond the standard trailer.
- New work goes on a new branch plus a pull request. The user merges, never Claude.
- Server changes:
  1. Back up the file to `backup\` first.
  2. Test against a temp store (`CLIPPIP_STORE_DIR` env var) and a temp config (set `clippip_store.CONFIG_PATH` to a temp file in the test), on a throwaway port with clipboard writes mocked.
  3. Restart the live server by exact PID only: look up the PID listening on 5051, confirm its command line contains `clipboard_sync`, stop that PID, then run `Start-ScheduledTask ClipboardSyncServer`.
  4. Measure handles and working set before and after about 200 requests.
- Phone install: Sideloadly, free Apple ID. It re-signs every 7 days.

## Rules and gotchas

- Never kill processes by name, only by exact PID.
- The server console is cp1252. Any `print` that carries user text must use `!a` or `ascii()`, otherwise a non-ASCII rule or app name raises inside the request.
- `re.error` is not a `ValueError`.
- The Bash tool turns `\t` inside a heredoc into a real tab in python source. Write files with the Write or Edit tool instead.
- A hook blocks any Bash command containing the word `python3`. Edit files that need that word (the workflow file) with the Edit tool.
- Windows refuses `bind()` on some free-looking ports (8791 gave WinError 10013). Tests bind port 0 and read the port back.
- `/clip/push` with `copy: true` writes the user's REAL clipboard. Tests must stub `set_windows_clipboard`, never let it through.
- Swift: `Dictionary(uniqueKeysWithValues:)` rejects `Dictionary.Element`; map to plain tuples first. That was the one compile error in 1.6.
- Do not put `@MainActor` on an `ObservableObject` in this codebase; the other models are plain classes whose completions already hop to the main thread.
- GitHub macos-15 runners do not always list an "iPhone 16" simulator. The workflow picks any available iPhone simulator by id.
- The app lists Library tabs once per launch. Reopen the Library to see new tabs.
- The keyboard is linked to the app through a `clippip-setup:` clipboard string because the unsigned build has no app group.
- The repo is public: no token, IP address or personal paths in committed files.
- The real Windows file-copy clipboard read (`CF_HDROP`) for exclusions was only tested with a mocked clipboard.

## Open items

- **Phone test of 1.6** (sideload `ClipPiP_1.6.ipa`):
  - Long press a prompt clip > "Edit prompt": do the buttons load from the PC, does a transform change the text, does Undo work, does Copy land on both clipboards, does Save make a new clip?
  - Check the keyboard shows (Settings > General > Keyboard > Keyboards > ClipPiP > Allow Full Access).
  - Create the source automations (Shortcuts > Automation > App > Reddit > Is Opened > Run Immediately > Set Current App = Reddit; and Is Closed > Clear Current App = Reddit; same pair for the browser), copy text in the Reddit app and on reddit in the browser, then check the `from reddit` tab and the `[origin-probe]` line in the server log.
  - Copy a link and confirm a new row in the browsing history db plus a `[link] captured` line.
- **Build the app and check the tab tree on the phone**: the Library sidebar should show chevrons on
  `mixes`, `prompt presets`, `test`, `uc`, `shota`, `todd prompts`, `ditto mixes` and `ditto characters`,
  and the open groups should survive a relaunch. Reopen the Library to pick up the new tabs.
- The Ditto groups are read only on purpose. If the user wants rename / move / delete on them, that is a
  separate decision: live writes work with Ditto open, deletes need Ditto closed plus a `MainDeletes` row.
- Pull request #3 is open for the user to review and merge. `clip-source-app` still has no pull request.
- Build the 3 tab split and the card feed (the design above).
- User decides whether to hide the 9 old PC clips that match the exclusion rules (settings page).
- User has not approved the AI organizer touching the real CopyQ `&clipboard` and `temp` tabs.
- Kanban card "Shortcut doesn't start PiP" is untouched. It is an iOS limit and needs a phone test.
