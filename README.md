# ClipPiP

Seamless iOS to windows clipboard sync that stays in the background with Picture-in-Picture and shares every copy you make to a server on your PC. Everything is local between your devices so no security/privacy concerns


<img width="550" height="1024" alt="image" src="https://github.com/user-attachments/assets/57090030-df87-403c-826c-3bc3c609c0c7" />


- Phone to PC: every copy on the phone is sent to a server on your PC (text and images). Images clips can be stored on your laptop to save on phone storage.
- PC to phone: the app polls the server once a second and puts new PC copies (text and images)
  instantly on the phone clipboard. This can be switched off in the Clips tab. 
- The clip list survives app restarts. Images are never stored on the phone, they are loaded from the PC.
- Library tab: browse and search clips that live on the PC (the app's clip history database and any PC clipboard manager you use with groups/tab features), with vertical tabs, tap copies, long press previews.

## Build
GitHub Actions builds an unsigned `ClipPiP.ipa` (Actions tab > build-ios > Artifacts).
Install it with Sideloadly (free Apple ID re-signs every 7 days).

## Use
1. Install the IPA, open ClipPiP, enter your server URL and token.
2. Settings > ClipPiP > Paste from Other Apps > Allow.
3. Tap Start PiP (or run a Shortcut that opens `clippip://start`; iOS 16+ also has a "Start PiP" action).
4. Copy anything on either device; it lands on the other one.

Shortcut URLs: `clippip://start`, `clippip://stop`.

## Server contract
All requests carry `?token=<token>`.

- `POST /set` with `Content-Type: application/x-www-form-urlencoded`, body `text=<percent-encoded>`,
  or `Content-Type: image/png` with the raw PNG bytes. Optional headers `X-Device`, `X-Clip-Url`.
  HTTP 200 = sent; the optional response header `X-Clip-Id` is the stored clip's id.
- `GET /poll?seq=<n>` returns `{"seq": n, "changed": bool, "kind": "text"|"image", "text": "...", "id": n}`.
  Send `seq=-1` first to get the current number without any clip.
- `GET /clip/file?id=<n>` and `GET /clip/thumb?id=<n>` return a stored clip (image) and its thumbnail.
- `GET /lib/tabs` returns `{"tabs": [{"id": "...", "label": "..."}]}`.
- `GET /lib/items?tab=<id>&q=<search>&offset=<n>&limit=<n>` returns
  `{"total": n, "items": [{"key", "kind", "text", "note", "url", "img"?, "thumb"?}]}`;
  `img` and `thumb` are server paths.
