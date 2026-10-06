# GoldWare OS architecture

Read this before touching any part. It is the interface between the app, the dashboard, and setup.

## Layout
```
goldware.default.json   tracked defaults. Never edited by users.
goldware.json           the user's live config (gitignored). Created by setup from the default.
                        Readers: load goldware.json if valid, else goldware.default.json, and report why.
data/                   gitignored user data: tasks.json, notes.json, onboarding.json (tour progress), drafts/
app/                    Swift app (SwiftPM target GoldWareOS). build.sh -> app/build/GoldWareOS.app
server/goldware_server.py   local server, Python 3.9 stdlib only (macOS Command Line Tools python3)
dashboard/index.html    the dashboard page (single file, vanilla JS/CSS, no build step, no CDN)
dashboard/gestures.js   animated demos of every Vision gesture (GoldWareGestures.list/render), with
                        gestures.css and the gallery gestures.html. Its catalog generates docs/GESTURES.md
                        (scripts/gestures_doc.py); tests/test_gestures.py checks it against the Swift gestures
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
- GET /api/onboarding   {state: {status: new|open|done|skipped, chapter, seen: [id], checks: [id], updated},
                        chapters: [welcome, permissions, voice, vision, office, reshape, help],
                        permissions: {microphone, accessibility, speech, camera, calendar, automation, updated,
                        milestones: [id]} | null}. state is data/onboarding.json; permissions is read from the
                        app's status.json in its data folder (GOLDWARE_DATA), only those fields, null when the
                        app has not run.
- POST /api/onboarding  merge {status?, chapter?, seen?, checks?, reset?: true}; ids are short slugs. 400 on bad input.
- Office (server/office.py, shown by the Office tab). Reads, any same-host request:
  GET /api/office/agents  {generated_at, agents: [{id, name, kind: hermes|claude|codex, title, model, provider,
                          activity, working, tty, cwd, pid, started_at, last_at, helpers, todos, closing}],
                          gateway: {running}, rack: {ollama, units}}
  GET /api/office/screen?id=<agent id>   {id, tty, activity, screen} the last 60 lines of its terminal
  GET /api/office/helper?id=<helper id>  {id, owner, owner_title, helper, steps} a helper that is still out
  GET /api/office/chat?id=<agent id>     {id, turns: [{kind: you|did|said, text}] | null} the latest turns in plain
                          words (Hermes from state.db, Claude Code from its transcript; null for Codex)
  GET /api/office/settings  {topics: [{id, label, dir, exists}], presets: [{id, label, command, available}], limits}
                          what the New agent menu and its editor show (office.topics and office.presets in goldware.json,
                          else the defaults in goldware.default.json; available = the program is on PATH)
  GET /api/office/board   {project, tasks, ideas, suggestions, runs, progress} (data/office-board.json)
  GET /api/office/usage   {plans: [{id, name, windows, out, back_at, top, error}], hours, checked_at}
  Writes, JSON POST only, and only from the dashboard itself (Origin or Referer must be this server's own
  127.0.0.1 or localhost address, no cross-site Sec-Fetch-Site; otherwise 403):
  POST /api/office/send   {id, text} types one line into that agent's terminal, then Return
  POST /api/office/focus  {id}       brings that agent's terminal tab to the front
  POST /api/office/answer {id, answers: [{picks: [index], other: text}]} answers the multiple-choice question (Hermes'
                          clarify tool) a Hermes agent is waiting on, by typing the keys into its iTerm session, one
                          per question. 422 unless its newest message is that question and its terminal shows it.
  POST /api/office/dismiss {id, step: check|ask|close} check: 409 with the reason while it works or has helpers out.
                          ask: types "Anything else before we dismiss you?" through the send path. close: re-checks
                          (409), sends HUP, TERM, KILL (0.8 s apart) to that tty's processes except login, pid 1,
                          this server and its parent, then closes only that iTerm session or Terminal window
                          (the tty is an osascript argument; the app is never quit). Bad step 422, gone 404.
                          With GOLDWARE_OFFICE_DRY_RUN=1 the signals are only recorded in office.DISMISS_LOG.
  POST /api/office/board  {action: project|add|assign|done|reopen|remove|lab|seen|regroup|ungroup, ...}
                           (regroup {table}: one button-only model run; the board keeps groupings[table])
  POST /api/office/new    {type, topic} ids only. The server finds the folder and command in goldware.json and opens
                          one terminal window (iTerm, else Terminal) running `cd <shlex-quoted folder> && <command>`.
                          Unknown id 422, missing folder 409, program not installed 422, one window per 5 s (429)
  POST /api/office/settings  {topics?: [{label, dir}], presets?: [{label, command}]} validates (names 1 to 40 characters,
                          at most 20 of each, folders absolute or ~/ and existing, commands one line under 200
                          characters with no control characters), makes slug ids, and writes only office.topics and
                          office.presets in goldware.json (temp file + rename; other keys kept; created from the
                          defaults when absent)
- GET /custom/office.css  the user's own Office CSS from custom/office.css (git-ignored), 404 when absent. Only that
  one file, never a path under custom/, and a symlink out of custom/ is refused. Loaded after /dashboard/office.css.
  Safety: the tty always comes from a fresh process scan for that request, never from the page. It must look
  like ttysNNN and belong to a detected agent, else 404. The text goes to osascript as an argument, never as
  script source; control characters are stripped, 2000 characters max, one line per 2 seconds per agent.
  Hermes lines are sent as /queue <text> unless they start with /. GOLDWARE_OFFICE_DRY_RUN=1 builds the
  osascript command and runs nothing (tests). GOLDWARE_OFFICE_EMPTY=1 forces an empty office, with no
  agent scan and no network (tests, screenshots). GOLDWARE_HERMES_HOME, CLAUDE_CONFIG_DIR, CODEX_HOME,
  GOLDWARE_OLLAMA_URL (or "off"), GOLDWARE_OFFICE_PS_FILE (a saved ps listing) override where it looks.
  The new-agent command runs in the user's own terminal and is written by the user; only a same-origin request can
  change it. GOLDWARE_OFFICE_TERMINAL=iTerm|Terminal forces which terminal opens (tests).
- Data lives in data/ at the repo root (GOLDWARE_DATA_ROOT overrides, for tests).

## App rules
- Bundle io.goldware.os, binary GoldWareOS, data folder ~/Library/Application Support/GoldWare OS
  (GOLDWARE_DATA overrides). Env vars GOLDWARE_*. Port from config (default 4188).
- The app starts the server with `/usr/bin/env python3 server/goldware_server.py` from the repo root
  when /api/work does not answer, and stops it on quit if it started it.
- Dashboard window: four tabs in this order, data-tab="office" | "dashboard" | "voice" | "vision", buttons with class
  "topbar-tab" (DashboardWindow.go(tab:) clicks them). Cmd+1 to 4 follow the same order. The page opens on the
  Dashboard unless the URL has #office.
- First-run tour: dashboard/tour.js and tour.css, a dialog over any tab. It opens by itself only while
  /api/onboarding says status "new", saves every step, and is reopened from the top bar Tour button or the
  Welcome card. ?tour-demo opens it without saving (screenshots), ?tour=<chapter> opens one chapter. The
  Vision chapter draws gestures only through GoldWareGestures.list() and .render(el, id, {loop: true,
  size: 'm'}) from dashboard/gestures.js, placing each in a section by id and mode; any it does not
  recognise go under "More gestures", so a new gesture always appears. The unlock gesture is private: the
  tour skips the library's entry for it and shows only its own "set or use your unlock gesture" card.
- The app writes status.json every 30 s and at once after a first-time milestone (Tour.mark in Tour.swift:
  dictated, assistant, wake, vision-on, vision-unlocked, quadrants, scan-filed, lets-work, lock-up, clear-out),
  with the camera, speech, calendar and iTerm Automation states read without prompting.
- The Office tab is a section of dashboard/index.html plus dashboard/office.js, office-cast.js (the characters, drawn
  from small pixel grids, no image files) and office.css (served from /dashboard/). You are the boss character at the front desk; there is no mascot.
- Nothing personal: no personal names, clients, businesses, emails, or paths.
  `scripts/check_private.sh` must pass.
- House style: no em dashes in UI strings, docs, or comments. Calm dark UI: house palette
  (near-black #0d0c0a background, cream text, gold #C9A24A accent), fonts DM Sans, Instrument Serif,
  JetBrains Mono (bundled, OFL).
