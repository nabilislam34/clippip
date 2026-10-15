# ClipPiP PC server

The Windows side of ClipPiP: clipboard sync server (port 5051), clip store, rules sorter, prompt transforms.
Live copy runs from the user's `clipboard_sync` folder; this folder mirrors it.

Put the shared token in `clippip_secrets.json` next to `clipboard_sync_server.py`:

    {"token": "your-token"}

Not in the repo: `clippip_secrets.json`, `clippip_config.json` (personal tabs), logs, the clip database.
