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
- letsWork {command, terminal, profile}: what Let's work opens per quadrant (terminal must be "iTerm"; profile defaults to "GoldWare", installed by setup).
- Dashboard shortcuts: the Shortcuts card (type `shortcuts`) and Voice tab buttons are `goldwareos://lets-work`, `lock-up`, `clear-out` links. The app registers the scheme (Info.plist in app/build.sh), `ShortcutRoute` whitelists the three routes, and each runs the same handler as the voice phrase.
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
- Office (server/office.py, shown by the Office tab). Reads, any same-host request:
  GET /api/office/agents  {generated_at, agents: [{id, name, kind: hermes|claude|codex, title, model, provider,
                          activity, working, tty, cwd, pid, started_at, last_at, helpers, todos, closing}],
                          gateway: {running}, rack: {ollama, units}}
  GET /api/office/screen?id=<agent id>   {id, tty, activity, screen} the last 60 lines of its terminal
  GET /api/office/helper?id=<helper id>  {id, owner, owner_title, helper, steps} a helper that is still out
  GET /api/office/board   {project, tasks, ideas, suggestions, runs, progress} (data/office-board.json)
  GET /api/office/usage   {plans: [{id, name, windows, out, back_at, top, error}], hours, checked_at}
  Writes, JSON POST only, and only from the dashboard itself (Origin or Referer must be this server's own
  127.0.0.1 or localhost address, no cross-site Sec-Fetch-Site; otherwise 403):
  POST /api/office/send   {id, text} types one line into that agent's terminal, then Return
  POST /api/office/focus  {id}       brings that agent's terminal tab to the front
  POST /api/office/board  {action: project|add|assign|done|reopen|remove|lab|seen, ...}
  Safety: the tty always comes from a fresh process scan for that request, never from the page. It must look
  like ttysNNN and belong to a detected agent, else 404. The text goes to osascript as an argument, never as
  script source; control characters are stripped, 2000 characters max, one line per 2 seconds per agent.
  Hermes lines are sent as /queue <text> unless they start with /. GOLDWARE_OFFICE_DRY_RUN=1 builds the
  osascript command and runs nothing (tests). GOLDWARE_OFFICE_EMPTY=1 forces an empty office, with no
  agent scan and no network (tests, screenshots). GOLDWARE_HERMES_HOME, CLAUDE_CONFIG_DIR, CODEX_HOME,
  GOLDWARE_OLLAMA_URL (or "off"), GOLDWARE_OFFICE_PS_FILE (a saved ps listing) override where it looks.
- Data lives in data/ at the repo root (GOLDWARE_DATA_ROOT overrides, for tests).

## App rules
- Bundle io.goldware.os, binary GoldWareOS, data folder ~/Library/Application Support/GoldWare OS
  (GOLDWARE_DATA overrides). Env vars GOLDWARE_*. Port from config (default 4188).
- The app starts the server with `/usr/bin/env python3 server/goldware_server.py` from the repo root
  when /api/work does not answer, and stops it on quit if it started it.
- Dashboard window: four tabs, data-tab="dashboard" | "voice" | "vision" | "office", buttons with class
  "topbar-tab" (DashboardWindow.go(tab:) clicks them).
- The Office tab is a section of dashboard/index.html plus dashboard/office.js and office.css (served from
  /dashboard/). You are the boss character at the front desk; there is no mascot.
- Nothing personal: no personal names, clients, businesses, emails, or paths.
  `scripts/check_private.sh` must pass.
- House style: no em dashes in UI strings, docs, or comments. Calm dark UI: house palette
  (near-black #0d0c0a background, cream text, gold #C9A24A accent), fonts DM Sans, Instrument Serif,
  JetBrains Mono (bundled, OFL).
