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
| `letsWork` | What the "Let's work" voice phrase and two-hand gesture open: one iTerm window per screen corner. `command` runs in each (empty opens a plain shell), `terminal` is `"iTerm"`, `profile` is an iTerm profile name (default `GoldWare`, installed by setup from `app/Resources/iTerm/goldware-profile.json` into iTerm's DynamicProfiles folder; a missing profile falls back to the default one, empty always uses the default) | `{"command": "claude", "terminal": "iTerm", "profile": "GoldWare"}` |
| `accentColor` | Accent as `#RRGGBB` | `"#4A9CC9"` |
| `port` | Dashboard server port, whole number 1024 to 65535, not 4177 (default 4188). Restart the app after changing it | `4188` |
| `models.local` | Ollama model tag | `"gemma4:e4b"` |
| `models.keepAlive` | How long Ollama keeps the language model in RAM after use (`"5m"`, `"0"` to unload at once, `"-1"` to keep loaded). Keep it short on a 16 GB Mac | `"5m"` |
| `models.whisper` | Speech model file name under `~/Library/Application Support/GoldWare OS/models/` | `"ggml-small.en-q5_1.bin"` |
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

(`make install` does the same but skips the copy when nobody can answer its question, as when an agent runs it.) Quit and reopen the app; macOS may ask for the permissions again. `make test` runs the Python tests and the hand, quadrants, chord, wake, and shelf self-tests; run others yourself, for example `GOLDWARE_DATA=$TMPDIR/gw app/.build/release/GoldWareOS --test-terminal-commands`.

## Where data lives

| What | Where |
|---|---|
| Your config | `goldware.json` (repo root, gitignored) |
| Tasks, notes, drafts | `data/` in the repo root (gitignored). `GOLDWARE_DATA_ROOT` overrides it |
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
