# ClipPiP

iOS clipboard monitor that stays in the background with Picture-in-Picture and shares every copy you make to a server on your PC.


<img width="550" height="1024" alt="image" src="https://github.com/user-attachments/assets/57090030-df87-403c-826c-3bc3c609c0c7" />



## Build
GitHub Actions (macos-14) builds an unsigned `ClipPiP.ipa` (Actions tab > build-ios > Artifacts).
Install it with Sideloadly (free Apple ID re-signs every 7 days).

## Use
1. Install the IPA, open ClipPiP, enter your server URL and token.
2. Settings > ClipPiP > Paste from Other Apps > Allow.
3. Tap Start PiP (or run a Shortcut that opens `clippip://start`; iOS 16+ also has a "Start PiP" action).
4. Copy anything on the phone; it shows up in the list and lands on the PC clipboard.

Shortcut URLs: `clippip://start`, `clippip://stop`.

## Server contract
- `POST /set?token=...` with `Content-Type: application/x-www-form-urlencoded`, body `text=<percent-encoded>`
- or `Content-Type: image/png` with the raw PNG bytes
- HTTP 200 = sent.
