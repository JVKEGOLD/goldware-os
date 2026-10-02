# Customizing GoldWare OS

This is the map for you and your AI agent. Most changes are one edit to `goldware.json` in the repo root. Your live config is `goldware.json` (gitignored, created by setup from `goldware.default.json`). Never edit the default file.

After any edit, validate:

```sh
python3 server/goldware_server.py --check
```

Then `make check` for the full gate. Back up first: `cp goldware.json goldware.json.bak` (the server also keeps `goldware.json.bak` when you save from the dashboard).

## goldware.json fields

| Field | Meaning | Example |
|---|---|---|
| `assistantName` | Name shown everywhere and used in prompts (1 to 24 chars) | `"Juno"` |
| `wakePhrase` | Phrase that wakes the assistant. Must not be blank (the app rejects a blank phrase and falls back to defaults, although `--check` does not catch it) | `"Hey Juno"` |
| `wakeAliases` | Other spellings the recognizer may produce (case-insensitive, punctuation-tolerant) | `["hey june oh", "hey juneo"]` |
| `letsWork` | What the "Let's work" voice phrase and two-hand gesture open: one iTerm window per screen corner. `command` runs in each (default `hermes`, a Hermes agent on its default model; setup asks Claude or Codex and sets that default to Claude Opus 5.5 or GPT 5.5, rerun with `scripts/setup.sh --only agent --agent codex` to switch; `/model` in any window switches to another model, `hermes model` changes the default; `hermes -m <model> --provider <p>` pins a model; empty opens a plain shell; a goldware.json without `letsWork` gets these defaults), `terminal` is `"iTerm"`, `profile` is an iTerm profile name (default `GoldWare`, installed by setup from `app/Resources/iTerm/goldware-profile.json` into iTerm's DynamicProfiles folder; a missing profile falls back to the default one, empty always uses the default) | `{"command": "claude", "terminal": "iTerm", "profile": "GoldWare"}` |
| `accentColor` | Accent as `#RRGGBB` | `"#4A9CC9"` |
| `port` | Dashboard server port, whole number 1024 to 65535, not 4177 (default 4188). Restart the app after changing it | `4188` |
| `models.local` | Ollama model tag | `"gemma4:e4b"` |
| `models.keepAlive` | How long Ollama keeps the language model in RAM after use (`"5m"`, `"0"` to unload at once, `"-1"` to keep loaded). Keep it short on a 16 GB Mac | `"5m"` |
| `models.whisper` | Speech model file name under `~/Library/Application Support/GoldWare OS/models/` | `"ggml-small.en-q5_1.bin"` |
| `office.topics` | The folders New agent can start in: a list of `{id, label, dir}`. `dir` is absolute or starts with `~/`. Easiest to change with Edit in the New agent menu | `[{"id": "home", "label": "Home", "dir": "~"}]` |
| `office.presets` | The agents New agent can start: a list of `{id, label, command}`. `command` is one line you run in a terminal, for example `hermes`, `claude` or `codex` | `[{"id": "codex", "label": "Codex", "command": "codex"}]` |
| `dashboard.layout` | A label only: it must be text but nothing reads it. Card order in `dashboard.cards` is what is displayed | `"starter"` |
| `dashboard.cards` | Ordered list of cards | see below |

## Cards

Each card: `{ "id": "unique-slug", "type": "...", "title": "...", "size": "s" | "m" | "l" | "w", "options": {} }`. Ids must be unique.

| Type | What it shows | Options |
|---|---|---|
| `welcome` | Intro and tips | none |
| `clock` | Date and time | none |
| `shortcuts` | One-click Let's work, Lock up and Clear out buttons, each showing its voice phrase and gesture (the buttons are fixed, not configurable) | none |
| `tasks` | Your task list (stored in `data/tasks.json`) | none |
| `notes` | Free text, saved per card id | none |
| `links` | Link list | `links`: `[{ "label": "Docs", "url": "https://example.com" }]` |
| `system` | CPU, memory, disk | none |
| `agents` | Running local AI processes (ollama, whisper-server, hermes, claude, codex) | none |
| `embed` | A web page in a frame (`http://`, `https://`, or a `/path` on this server; many sites refuse to be framed) | `url` |
| `html` | Your own HTML in a sandboxed iframe. Scripts run, but the card cannot reach the dashboard or `/api/...`. If it fetches a public web API, that request leaves this Mac | `html` |

Examples:

```json
{ "id": "reading", "type": "links", "title": "Reading list", "size": "m",
  "options": { "links": [ { "label": "Hacker News", "url": "https://news.ycombinator.com" } ] } }
```

```json
{ "id": "quote", "type": "html", "title": "Quote", "size": "s",
  "options": { "html": "<p style='font:20px serif'>Make it yours.</p>" } }
```

## Adding a new card type

Card rendering lives in `dashboard/index.html` (single file, vanilla JS and CSS, no build step, no CDN). There is no registry object. A card type is wired in four places, and the server rejects the config if the first is missing:

1. `server/goldware_server.py`: add the name to the `CARD_TYPES` list near the top (this is what `--check` validates against).
2. `dashboard/index.html`: add `["name", "Label"]` to the `TYPES` array (the add-card menu) and an entry to `DEFAULT_TITLE` and `DEFAULT_SIZE`.
3. `dashboard/index.html`: add `case "name": return nameBody(body, c);` to the `switch (c.type)` in `fillBody(body, c)`, and write `nameBody`, which appends elements to `body` (see `clockBody` or `linksBody`; `h(tag, attrs, ...children)` builds elements).
4. If the card needs data, fetch from the local server (`/api/...`, same origin). A new endpoint goes in `server/goldware_server.py` (Python stdlib only) with a test in `tests/test_server.py`.

Then use the new type in `goldware.json`, run `python3 server/goldware_server.py --check`, and reload http://127.0.0.1:4188.
Style with the house palette: background `#0d0c0a`, cream text, gold `#C9A24A`, fonts DM Sans, Instrument Serif, JetBrains Mono. No em dashes in UI text.

## Rename the assistant and wake phrase

Config only: set `assistantName`, `wakePhrase`, and a few `wakeAliases` (how the recognizer might mishear it), then quit and reopen the app. Aliases matter: speech recognition often splits or respells unusual names.

## Change the model

1. Pull it: `ollama pull <tag>` (browse tags at https://ollama.com/library).
2. Set `models.local` to the tag in `goldware.json`.
3. Validate and restart the app. Check with `make doctor`.

Guide: under 12 GB RAM use `gemma4:e2b`, 12 to 28 GB use `gemma4:e4b`, 28 GB or more can use `gemma4:12b`.

To use a different speech model, put the `ggml-*.bin` file in `~/Library/Application Support/GoldWare OS/models/` and set `models.whisper` to its file name.

## Add a voice command

Voice commands are Swift code in `app/Sources/GoldWareOS`:

- Fixed phrases: `AppDelegate.swift`, function `handleAssistant(_:record:)`. It first checks `LetsWork.matches`, then `TerminalCommands.matchesFinishUp`, `matchesLockUp`, and `matchesClearOut` (defined with their actions in `TerminalCommands.swift`). For a phrase such as "open Spotify", write a `matchesX` function and an action the same way, call it from `handleAssistant` before the generic request handling, and show feedback with `self.hud.show(...)`.
- Anything else goes to the language model in `Assistant.swift`: `interpret` returns an intent from a fixed list (task, draft, note, paste, recall, agenda, complete, undo, closeout, vision_on, vision_off) and `perform` acts on it. A new intent means editing the prompt text, the schema `enum`, and `perform`.
- Tests are `--test-*` flags handled in `app/Sources/GoldWareOS/main.swift` (phrase matching: `--test-terminal-commands`, `--test-lets-work`). Add cases there.

Pattern: find an existing command, copy its shape, add your trigger phrases and the action, then:

```sh
make app
scripts/setup.sh --only install --yes
```

(`make install` does the same but skips the copy when nobody can answer its question, as when an agent runs it.) Quit and reopen the app; macOS may ask for the permissions again. `make test` runs the Python tests and the hand, quadrants, chord, wake, shelf, Let's work, and terminal-commands self-tests; run others yourself, for example `GOLDWARE_DATA=$TMPDIR/gw app/.build/release/GoldWareOS --test-terminal-commands`.

## How the Office finds agents

The Office tab shows one desk per agent running in a terminal on this Mac. Every few seconds the server reads `ps` and picks out:

- **Claude Code** and **Codex**: a `claude` or `codex` process attached to a terminal (a tty). The title is "Claude Code in <folder>"; it counts as busy while it uses CPU.
- **Hermes**: the chats in `~/.hermes/runtime/active_sessions.json` whose process is still alive, with the title, model, and whether a turn is running read from `~/.hermes/state.db` (opened read only). Without Hermes installed this part is simply empty.
- **Ollama**: loaded models from its local API (`http://127.0.0.1:11434`), shown with the rest of the rack. Ollama runs no terminal, so it has no desk.

Each agent gets a character from the cast (Bolt, Mocha, Pixel, Latte, Sprout, Ember, Beans, Frost, Wisp, Biscuit) and keeps it while it stays; past ten it is "Agent 11" and so on. Agents group into tables by the folder they work in, and each table has a whiteboard for its tasks. Set `GOLDWARE_HERMES_HOME`, `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, or `GOLDWARE_OLLAMA_URL` before starting the server if your tools keep their files elsewhere. The board (tasks, ideas, lab) is saved in `data/office-board.json`. Plan usage uses the sign-ins Claude Code and Codex already keep on this Mac and never refreshes them. Talking to a terminal works with iTerm and Terminal and needs the Automation permission the first time.

## The boss

The boss at the front desk can run the other agents for you. It only acts when asked; nothing runs on a timer.

- **Ask it**: click the front desk, type what you want ("put two agents on the Sunrise site, one for copy and one for the form"), and press Ask. The first request opens the boss: a Hermes chat in its own terminal, working in `data/boss`. After that, clicking the front desk opens the boss's console, like any agent's, and you type to it there. Dismiss it like any agent; the next request opens a new one.
- **Report to it**: the **Report to boss** button on any agent's console sends that agent to the boss, which reads its chat and decides the next step. Or tell the agent "report to the boss": setup installs a small Hermes skill (`~/.hermes/skills/goldware/goldware-office`) so it runs `goldware-office report "..."` itself. A report starts the boss if it is not in.
- **What it can do**: the boss uses the `goldware-office` command (setup links it into `~/.local/bin`; it is `scripts/office`). It only calls this server's Office endpoints, so it can do what the Office page can and nothing more:

  | Command | What it does |
  |---|---|
  | `goldware-office agents` | every agent: id, name, kind, status, title, folder |
  | `goldware-office chat ID` / `screen ID` | read an agent's conversation or terminal |
  | `goldware-office send ID "text"` | type one line to an agent |
  | `goldware-office presets` | your New agent types and topics |
  | `goldware-office new --type T --topic P "task"` | open a new agent and hand it the task |
  | `goldware-office dismiss ID` | close an idle agent (refused while it works) |
  | `goldware-office report "note"` | report the agent you are in to the boss |
  | `goldware-office boss "text"` | ask the boss from any terminal |

- Its brief is `data/boss/AGENTS.md`, rewritten each time it starts: act only on your requests and on reports, read before acting, start at most three agents without asking, never dismiss unless you said so, and end each turn with a short summary.
- It runs on your Hermes default model. It needs Hermes; without it the front desk says so.

## New agent, topics and agent presets

The Office's **New agent** button opens a terminal window that runs `cd <folder> && <command>`. The arrow beside it picks which topic (folder) and which agent (command). Choose **Edit** there to add, rename, remove or reorder them (each topic has a **Choose…** button that opens a Finder window, so you pick the folder instead of typing its path); Save writes only `office.topics` and `office.presets` into `goldware.json` and keeps everything else. You can also edit the file by hand:

```json
"office": {
  "topics": [
    { "id": "home", "label": "Home", "dir": "~" },
    { "id": "site", "label": "My website", "dir": "~/code/site" }
  ],
  "presets": [
    { "id": "hermes", "label": "Hermes on Claude", "command": "hermes" },
    { "id": "claude-code", "label": "Claude Code", "command": "claude" },
    { "id": "codex", "label": "Codex", "command": "codex" }
  ]
}
```

- A name is 1 to 40 characters, at most 20 topics and 20 agents. A folder must exist and be absolute or start with `~/`. A command is one line under 200 characters with no control characters.
- `id` is made from the name when you save in Edit; if you edit by hand, use a lowercase slug (letters, digits, dashes).
- An agent whose program is not on your PATH shows greyed out with "Not installed". A topic whose folder is gone shows with a dashed outline.
- The page sends only the ids of the topic and agent. The folder and the command always come from `goldware.json`, so nothing a web page sends can run something else. The command is yours: it runs in your own terminal, and only the dashboard itself can change it.
- `goldware.json` is git-ignored, so `make update` never touches your lists. If the file does not exist, Edit creates it from `goldware.default.json`.
- The new window opens in iTerm (profile from `letsWork.profile`), or Terminal if iTerm is not installed.

## Your own Office look (custom/office.css)

Put CSS in `custom/office.css`. The dashboard loads it after the built-in `dashboard/office.css`, so your rules win, and the whole `custom/` folder is git-ignored, so `make update` never overwrites it. Create the folder and file if they are missing, then reload the Office tab. There is no file by default and the page works fine without one.

```css
/* custom/office.css: a cooler room and bigger agent names */
#tab-office, .office-console { --office-edge: rgba(120, 180, 255, .30); --office-edge-hi: rgba(150, 200, 255, .6); }
.oh-brand b { color: #9fd0ff; }
.office-hit.qb .qb-ask { font-size: 13px; }
.oe-editor { width: min(640px, calc(100vw - 32px)); }
```

The room itself is drawn on a canvas, so CSS changes the panels, buttons, menus and the text over the room, not the pixel art (for the characters, see the next section). Only `/custom/office.css` and `/custom/office-cast.js` are served from that folder, nothing else in it.

## Your own agent characters (custom/office-cast.js)

The characters (Bolt, Mocha, Pixel and the rest) are drawn from small grids in `dashboard/office-cast.js`. To change how any of them look, put a call to `OfficeCast.customize` in `custom/office-cast.js`. Like `office.css`, it is git-ignored, so `make update` keeps it.

```js
// custom/office-cast.js: a red Bolt and a green-eyed Mocha
OfficeCast.customize({
  Bolt:  { color: '#c04040', pal: { b: '#c04040', h: '#e07070', s: '#902828' } },
  Mocha: { pal: { k: '#2f8f4f' } }
});
```

- `color` is the character's signature colour (its name, avatar and swatch). `pal` changes single grid colours and keeps the rest (letters: `o` outline, `b` body, `h` light, `s` shade, `w` white, `k` dark, `a` accent, `c` second accent, `p` cheek). `rows` replaces the whole grid: each row is the left half of the character, mirrored when drawn, and `.` is clear.
- The dictation pill at the bottom of the screen draws the same characters from the same two files, so your look shows there too. It picks up a saved change within a few seconds; reload the Office tab to see it there.
- Names that are not in the cast are ignored, and a file with a mistake in it leaves the built-in looks in place.

## Where data lives

| What | Where |
|---|---|
| Your config, including your New agent topics and agents | `goldware.json` (repo root, gitignored) |
| Your Office CSS and character looks | `custom/office.css`, `custom/office-cast.js` (gitignored) |
| Tasks, notes, drafts, the boss's folder (`data/boss`) | `data/` in the repo root (gitignored). `GOLDWARE_DATA_ROOT` overrides it |
| Models, app data, history | `~/Library/Application Support/GoldWare OS/` (`GOLDWARE_DATA` overrides it) |
| Whisper model | `~/Library/Application Support/GoldWare OS/models/` |
| Language models | managed by Ollama (`ollama list`) |
| Built app | `app/build/GoldWareOS.app`, installed copy at `/Applications/GoldWare OS.app` (it remembers this checkout's path, so keep the folder or set `GOLDWARE_ROOT`) |

## Example requests and the edits they map to

| You say | The agent does |
|---|---|
| "Call the assistant Juno" | `assistantName: "Juno"`, `wakePhrase: "Hey Juno"`, add aliases, validate, restart app |
| "Make the accent blue" | `accentColor: "#4A9CC9"`, validate |
| "Add a card with my three favorite sites" | append a `links` card with `options.links`, validate |
| "Put tasks first and make it wide" | reorder `dashboard.cards`, set `size: "w"` on the tasks card |
| "Embed my calendar" | add an `embed` card with `options.url` (the site must allow framing) |
| "Use a smaller model, my Mac is slow" | `ollama pull gemma4:e2b`, set `models.local`, restart app |
| "Add a weather card" | simplest: an `html` card that fetches a public weather API (see the privacy note above). Or a new card type, see "Adding a new card type" |
| "Add a voice command: open my notes" | new phrase matcher and action called from `handleAssistant` in `AppDelegate.swift`, `make app`, install, relaunch |
| "Undo that" | restore `goldware.json.bak` or revert the code with git, then `make check` |
