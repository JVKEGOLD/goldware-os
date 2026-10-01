# GoldWare OS app

The native macOS app: a menu bar assistant with voice dictation, a spoken assistant, hand-tracking
Vision mode, a control center, and a window for the dashboard served by `server/goldware_server.py`.
It is a SwiftPM executable target named `GoldWareOS`.

## Build

```
cd app
swift build -c release        # prints "Build complete!"
./build.sh                    # builds and signs build/GoldWareOS.app
```

Install by copying `build/GoldWareOS.app` to `/Applications` yourself. The build never does it.

## Configuration

The app reads `goldware.json` in the repo root, and falls back to `goldware.default.json` when the
file is missing or invalid (the reason is shown in the app). Settings used here: `assistantName`,
`wakePhrase`, `wakeAliases`, `accentColor`, `port`, `models.local`, `models.whisper`,
`letsWork.command`, `letsWork.terminal`, `letsWork.profile`.
The repo root is `GOLDWARE_ROOT`, or the checkout the app was built in.

## Self-tests

Run them with a throwaway data folder so they never touch real history:

```
GOLDWARE_DATA=$TMPDIR/gw-data .build/release/GoldWareOS --test-wake
```

Available: `--test-hand`, `--test-quadrants`, `--test-chord`, `--test-shelf`, `--test-wake`,
`--test-terminal-commands`, `--test-plan-usage`, `--test-work`, `--test-control-center`.
Renders: `--render-control-center out.png`, `--indicator-sheet out.png`.

## Where data lives

`~/Library/Application Support/GoldWare OS` (override with `GOLDWARE_DATA`): dictation history,
vocabulary, snippets, prompts, shelf, logs and the speech model in `models/`. Snippets stay on this
Mac and their values are never sent to a model. Tasks and drafts live in the repo's `data/` folder.
