<p align="center"><img src="app/Resources/goldware-logo.png" alt="GoldWare OS" width="160"></p>

# GoldWare OS

Your Mac, voice, vision, and a dashboard you reshape with your own AI. Everything runs locally.

- **Voice**: push-to-talk dictation and a voice assistant (whisper.cpp for speech, a local Ollama model for cleanup and understanding).
- **Vision**: Mac camera hand tracking (Apple Vision framework): hand mirror, pointer control, document scan.
- **Dashboard**: a local page at http://127.0.0.1:4188 that you customize by asking your AI agent.

## Requirements

- Apple Silicon Mac, macOS 14 or newer
- 16 GB RAM recommended (8 GB works with the small model)
- About 6 GB free disk

## Quickstart

```sh
git clone https://github.com/JVKEGOLD/goldware-os.git && cd goldware-os
```

Then either:

- paste [MASTER_PROMPT.md](MASTER_PROMPT.md) into your AI coding agent (Claude Code, Codex, Hermes, ...) and let it set things up, or
- run `make setup` yourself. `scripts/setup.sh --dry-run` shows what it would do first.

`make doctor` checks every piece and prints the fix command for anything missing.

## Memory tiers

| Memory | Tier | Local model |
|---|---|---|
| under 12 GB | small | `gemma4:e2b` |
| 12 to 28 GB | standard | `gemma4:e4b` |
| 28 GB or more | large | `gemma4:e4b` by default, `gemma4:12b` if you opt in |

## Privacy

Nothing leaves your Mac. Speech, language models, camera frames, tasks, and notes are all processed and stored locally. The plan usage card reads local CLI credentials only to show your own limits.

## Make it yours

GoldWare OS is meant to be reshaped. Rename the assistant, change the wake phrase, add dashboard cards, swap the model, or add voice commands by asking your AI agent. [docs/CUSTOMIZING.md](docs/CUSTOMIZING.md) maps every setting and where it lives.

## First launch (unsigned app)

The app is ad-hoc signed, not notarized. On first launch macOS may block it: right-click the app and choose Open, or go to System Settings > Privacy & Security and click Open Anyway. You will also be asked for Microphone, Accessibility, Speech Recognition, and Camera access.

## License

MIT, see [LICENSE](LICENSE). Bundled fonts are SIL OFL.

Made by [GoldWare](https://goldware.io).
