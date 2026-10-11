# ClipPiP

Seamless iOS to windows clipboard sync that stays in the background with Picture-in-Picture and shares every copy you make to a server on your PC. Everything is local between your devices so no security/privacy concerns


<img width="550" height="1024" alt="image" src="https://github.com/user-attachments/assets/57090030-df87-403c-826c-3bc3c609c0c7" />


- Phone to PC: every copy on the phone is sent to a server on your PC (text and images). Images clips can be stored on your laptop to save on phone storage.
- PC to phone: the app polls the server once a second and puts new PC copies (text and images)
  instantly on the phone clipboard. This can be switched off in the Clips tab. 
- The clip list survives app restarts. Images are never stored on the phone, they are loaded from the PC.
- Library tab: browse and search clips that live on the PC (the app's clip history database and any PC clipboard manager you use with groups/tab features), with vertical tabs, tap copies, long press previews.
- Tapping a clip also puts it on the PC clipboard. Long press to rename or delete a clip. Search matches
  text, names and tags, and the tag button filters by tag.
- Phone copies made in a browser are stored with the page they came from.
- Each phone clip shows the app it was copied in, and the Library gets a `from <app>` tab per app
  (`from reddit` holds Reddit app copies and copies from reddit pages in a browser). See "Which app a clip came from".
- ClipPiP keyboard: a custom keyboard whose keys search your PC clips; tapping a result types it into
  the app you are in. Add it in Settings > General > Keyboard > Keyboards, turn on Allow Full Access,
  then tap "Link the ClipPiP keyboard" in the app and open the keyboard once.

## Build
GitHub Actions builds an unsigned `ClipPiP.ipa` (Actions tab > build-ios > Artifacts).
Install it with Sideloadly (free Apple ID re-signs every 7 days).

## Use
1. Install the IPA, open ClipPiP, enter your server URL and token.
2. Settings > ClipPiP > Paste from Other Apps > Allow.
3. Tap Start PiP (or run a Shortcut that opens `clippip://start`; iOS 16+ also has a "Start PiP" action).
4. Copy anything on either device; it lands on the other one.

Shortcut URLs: `clippip://start`, `clippip://stop`.

## Which app a clip came from
iOS does not tell an app where a copy was made, so ClipPiP combines three hints and the server keeps the best:

1. What iOS itself recorded as the copying app. This is read through private fields that may not be
   available on your iOS version; when they are not, nothing is sent and the next hints are used.
2. Shortcuts automations (iOS 16+). For each app you care about, make two automations in
   Shortcuts > Automation > New Automation > App:
   - choose the app, tick only "Is Opened", "Run Immediately", action ClipPiP > "Set Current App", type the app's name;
   - choose the app, tick only "Is Closed", "Run Immediately", action ClipPiP > "Clear Current App", same name.
   Copies made while that app is open are labeled with the name you typed.
3. The clip itself: a copied page fragment or link names its site, and some apps leave a recognizable
   clipboard format (a Reddit share link, a Shortcuts result, a Reminders note).

## Server contract
All requests carry `?token=<token>`.

- `POST /set` with `Content-Type: application/x-www-form-urlencoded`, body `text=<percent-encoded>`,
  or `Content-Type: image/png` with the raw PNG bytes. Optional headers `X-Device`, `X-Clip-Url`
  (source page), `X-Clip-Types` (clipboard data types), and the percent-encoded source hints `X-Clip-Origin`
  (bundle id iOS recorded), `X-Clip-Origin-Name`, `X-Clip-App` (app reported by a Shortcuts automation),
  `X-Clip-Hosts` (comma separated sites inside a copied page fragment).
  HTTP 200 = sent; the optional response header `X-Clip-Id` is the stored clip's id.
- `GET /poll?seq=<n>` returns `{"seq": n, "changed": bool, "kind": "text"|"image", "text": "...", "id": n}`.
  Send `seq=-1` first to get the current number without any clip.
- `GET /clip/file?id=<n>` and `GET /clip/thumb?id=<n>` return a stored clip (image) and its thumbnail.
- `GET /lib/tabs` returns `{"tabs": [{"id": "...", "label": "..."}]}`.
- `GET /lib/items?tab=<id>&q=<search>&tag=<tag>&kind=<text|image>&offset=<n>&limit=<n>` returns
  `{"total": n, "items": [{"key", "kind", "text", "name", "note", "tags", "url", "sig", "img"?, "thumb"?}]}`;
  `img` and `thumb` are server paths.
- `GET /lib/tags?tab=<id>` returns `{"tags": [{"tag", "count"}]}`.
- `POST /lib/rename` `{"key", "sig", "name"}`, `POST /lib/delete` `{"key", "sig", "force"}`,
  `POST /lib/activate` `{"key", "sig"}` (put that clip on the PC clipboard). HTTP 409 carries
  `{"error": "pinned" | "changed"}`.
