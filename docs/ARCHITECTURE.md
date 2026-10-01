# GoldWare OS architecture

Read this before touching any part. It is the interface between the app, the dashboard, and setup.

## Layout
```
goldware.default.json   tracked defaults. Never edited by users.
goldware.json           the user's live config (gitignored). Created by setup from the default.
                        Readers: load goldware.json if valid, else goldware.default.json, and report why.
data/                   gitignored user data: tasks.json, notes.json, drafts/
app/                    Swift app (SwiftPM target GoldWareOS). build.sh -> app/build/GoldWareOS.app
server/goldware_server.py   local server, Python 3.9 stdlib only (macOS Command Line Tools python3)
dashboard/index.html    the dashboard page (single file, vanilla JS/CSS, no build step, no CDN)
docs/CUSTOMIZING.md     map of every setting, for humans and their AI agents
scripts/setup.sh        one-shot installer; scripts/check_private.sh privacy gate
tests/                  python unittest for the server and config
Makefile                setup, doctor, app, install, run-server, test, check
MASTER_PROMPT.md, README.md, LICENSE (MIT)
```
Repo root detection (app and server): the folder containing `goldware.default.json`.

## Config fields (goldware.json)
- assistantName (string, 1-24 chars): the name shown everywhere and used in prompts. Default "GoldWare".
- wakePhrase (string): e.g. "Hey GoldWare". wakeAliases (array of strings): other spellings the
  speech recognizer may produce. Matching is case-insensitive, punctuation-tolerant.
- accentColor (#RRGGBB). port (int, default 4188, 1024 to 65535, 4177 is rejected).
- models.local (Ollama model tag), models.whisper (file name under the app data folder models/).
- dashboard.layout (string), dashboard.cards (array of cards).
Card: { id (unique slug), type, title, size: "s" | "m" | "l" | "w", options: {} }
Card types: welcome, clock, tasks, notes, links (options.links [{label,url}]), system, agents,
embed (options.url), html (options.html, rendered in a sandboxed iframe srcdoc).

## Server API (127.0.0.1:<port> only, never 0.0.0.0)
- GET /                 dashboard/index.html. Static: /dashboard/*, /fonts/* from app/Resources/Fonts,
                        /logo.png from app/Resources/goldware-logo.png, /docs/* from docs/ (markdown as text).
- GET /api/config       {config, source: "goldware.json" | "default", error: string|null}
- POST /api/config      full config JSON. Validate; 400 {error} on bad input; write atomically,
                        keep goldware.json.bak. 200 {config}.
- GET /api/work         {today: "YYYY-MM-DD", tasks: [{id, title, status, revision, context, due_on,
                        priority, focus_on}]}  status in inbox|ready|doing|done|dropped.
- POST /api/work        create: {create: true, request_id, changes: {title, context, status?, due_on?, priority?}}
                        (idempotent on request_id, id = "t-" + first 12 hex of sha256(request_id)).
                        update: {id, based_on: revision, changes: {...}} -> 409 {error} when revision is stale.
                        revision = first 12 hex of sha256 of the task's canonical JSON without revision.
- GET/POST /api/notes   {notes: {cardId: text}}; POST {cardId, text}.
- GET /api/system       {cpu_percent, memory: {used_gb, total_gb}, disk: {free_gb, total_gb}}
- GET /api/agents       [{name, kind, pid, memory_mb}] for running ollama, whisper-server, hermes, claude, codex.
- Data lives in data/ at the repo root (GOLDWARE_DATA_ROOT overrides, for tests).

## App rules
- Bundle io.goldware.os, binary GoldWareOS, data folder ~/Library/Application Support/GoldWare OS
  (GOLDWARE_DATA overrides). Env vars GOLDWARE_*. Port from config (default 4188).
- The app starts the server with `/usr/bin/env python3 server/goldware_server.py` from the repo root
  when /api/work does not answer, and stops it on quit if it started it.
- Dashboard window: three tabs only, data-tab="dashboard" | "voice" | "vision", buttons with class
  "topbar-tab" (DashboardWindow.go(tab:) clicks them).
- Nothing personal: no personal names, clients, businesses, emails, or paths.
  `scripts/check_private.sh` must pass.
- House style: no em dashes in UI strings, docs, or comments. Calm dark UI: house palette
  (near-black #0d0c0a background, cream text, gold #C9A24A accent), fonts DM Sans, Instrument Serif,
  JetBrains Mono (bundled, OFL).
