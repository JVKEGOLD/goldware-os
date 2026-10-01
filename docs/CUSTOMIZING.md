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
| `wakePhrase` | Phrase that wakes the assistant | `"Hey Juno"` |
| `wakeAliases` | Other spellings the recognizer may produce (case-insensitive, punctuation-tolerant) | `["hey june oh", "hey juneo"]` |
| `accentColor` | Accent as `#RRGGBB` | `"#4A9CC9"` |
| `port` | Dashboard server port (default 4188) | `4188` |
| `models.local` | Ollama model tag | `"gemma4:e4b"` |
| `models.whisper` | Speech model file name under `~/Library/Application Support/GoldWare OS/models/` | `"ggml-small.en-q5_1.bin"` |
| `dashboard.layout` | Layout name | `"starter"` |
| `dashboard.cards` | Ordered list of cards | see below |

## Cards

Each card: `{ "id": "unique-slug", "type": "...", "title": "...", "size": "s" | "m" | "l" | "w", "options": {} }`. Ids must be unique.

| Type | What it shows | Options |
|---|---|---|
| `welcome` | Intro and tips | none |
| `clock` | Date and time | none |
| `tasks` | Your task list (stored in `data/tasks.json`) | none |
| `notes` | Free text, saved per card id | none |
| `links` | Link list | `links`: `[{ "label": "Docs", "url": "https://example.com" }]` |
| `system` | CPU, memory, disk | none |
| `agents` | Running local AI processes (ollama, whisper-server, hermes, claude, codex) | none |
| `embed` | A web page in a frame | `url` |
| `html` | Your own HTML in a sandboxed iframe | `html` |

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

Card rendering lives in `dashboard/index.html` (single file, vanilla JS and CSS, no build step, no CDN). The renderers are registered in a `CARD_TYPES` object that maps a type name to a render function. If your checkout names it differently, search `dashboard/index.html` for the object the built-in types (`clock`, `tasks`, ...) are registered in.

1. Add a renderer: a function that receives the card (`id`, `title`, `size`, `options`) and a container element, and fills the container. Register it, for example `CARD_TYPES.weather = (card, el) => { ... }`.
2. Fetch data from the local server (`/api/...`, same origin) if you need any. If you need a new endpoint, add it in `server/goldware_server.py` (Python stdlib only) and a test in `tests/`.
3. If the server validates card types, add the new name to its list of allowed types.
4. Use the new type in `goldware.json`, run `python3 server/goldware_server.py --check`, and reload http://127.0.0.1:4188.
5. Style with the house palette: background `#0d0c0a`, cream text, gold `#C9A24A`, fonts DM Sans, Instrument Serif, JetBrains Mono. No em dashes in UI text.

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

- `TerminalCommands.swift`: spoken commands that run actions.
- `Assistant.swift` (if present in your checkout): intent handling for the assistant. Otherwise search for where spoken text is matched to actions, for example `grep -rn "intent" app/Sources/GoldWareOS`.

Pattern: find an existing command, copy its shape, add your trigger phrases and the action, then:

```sh
make app && make install
```

Quit and reopen the app. Run `make test` (it includes the app self-tests) before you rely on it.

## Where data lives

| What | Where |
|---|---|
| Your config | `goldware.json` (repo root, gitignored) |
| Tasks, notes, drafts | `data/` in the repo root (gitignored). `GOLDWARE_DATA_ROOT` overrides it |
| Models, app data, history | `~/Library/Application Support/GoldWare OS/` (`GOLDWARE_DATA` overrides it) |
| Whisper model | `~/Library/Application Support/GoldWare OS/models/` |
| Language models | managed by Ollama (`ollama list`) |
| Built app | `app/build/GoldWareOS.app`, installed copy at `/Applications/GoldWare OS.app` |

## Example requests and the edits they map to

| You say | The agent does |
|---|---|
| "Call the assistant Juno" | `assistantName: "Juno"`, `wakePhrase: "Hey Juno"`, add aliases, validate, restart app |
| "Make the accent blue" | `accentColor: "#4A9CC9"`, validate |
| "Add a card with my three favorite sites" | append a `links` card with `options.links`, validate |
| "Put tasks first and make it wide" | reorder `dashboard.cards`, set `size: "w"` on the tasks card |
| "Embed my calendar" | add an `embed` card with `options.url` (the site must allow framing) |
| "Use a smaller model, my Mac is slow" | `ollama pull gemma4:e2b`, set `models.local`, restart app |
| "Add a weather card" | new renderer in `CARD_TYPES` in `dashboard/index.html`, then a card of that type in `goldware.json` |
| "Add a voice command: open my notes" | new case in `TerminalCommands.swift`, `make app`, `make install`, relaunch |
| "Undo that" | restore `goldware.json.bak` or revert the code with git, then `make check` |
