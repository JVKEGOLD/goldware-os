<p align="center"><img src="app/Resources/goldware-logo.png" alt="GoldWare OS" width="160"></p>

# GoldWare OS

Your Mac, voice, vision, and a dashboard you reshape with your own AI. Everything runs locally.

- **Voice**: push-to-talk dictation and a voice assistant (whisper.cpp for speech, a local Ollama model for cleanup and understanding).
- **Vision**: Mac camera hand tracking (Apple Vision framework): hand mirror, pointer control, document scan.
- **Dashboard**: a local page at http://127.0.0.1:4188 that you customize by asking your AI agent.

## Requirements

- Apple Silicon Mac, macOS 14 or newer
- 16 GB RAM recommended (8 GB works with the small model)
- About 15 GB free disk (the language model alone is 7 to 10 GB, plus the speech model and the build)
- Xcode Command Line Tools and Homebrew (setup tells you if they are missing)

## Quickstart

```sh
git clone https://github.com/JVKEGOLD/goldware-os.git && cd goldware-os
```

While the repository is private, sign in first (`brew install gh`, then `gh auth login`) and clone with `gh repo clone JVKEGOLD/goldware-os`. Keep the cloned folder where it is: the built app reads its config, server, and dashboard from it.

Then either:

- paste [MASTER_PROMPT.md](MASTER_PROMPT.md) into your AI coding agent (Claude Code, Codex, Hermes, ...) and let it set things up, or
- run `make setup` yourself. `scripts/setup.sh --dry-run` shows what it would do first.

Run `make setup` in a normal Terminal window: copying the app to /Applications is a question that is skipped when there is no keyboard attached (for example when an agent runs it). Agents should finish with `scripts/setup.sh --only install --yes` after you approve.

`make doctor` checks every piece and prints the fix command for anything missing.

## Memory tiers

| Memory | Tier | Local model |
|---|---|---|
| under 12 GB | small | `gemma4:e2b` |
| 12 to 28 GB | standard | `gemma4:e4b` |
| 28 GB or more | large | `gemma4:e4b` by default, `gemma4:12b` if you opt in (set `GOLDWARE_TIER=large` with `--yes`, or answer yes when asked) |

## Privacy

Nothing leaves your Mac. Speech, language models, camera frames, tasks, and notes are all processed and stored locally. The plan usage card reads local CLI credentials only to show your own limits.

## Make it yours

GoldWare OS is meant to be reshaped. Rename the assistant, change the wake phrase, add dashboard cards, swap the model, or add voice commands by asking your AI agent. [docs/CUSTOMIZING.md](docs/CUSTOMIZING.md) maps every setting and where it lives.

## First launch (unsigned app)

The app is ad-hoc signed, not notarized. On first launch macOS may block it: right-click the app and choose Open, or go to System Settings > Privacy & Security and click Open Anyway. You will also be asked for Microphone, Accessibility, Speech Recognition, and Camera access. Because the app is ad-hoc signed, every rebuild (`make app`, `make install`, rerunning setup) can reset those permissions; re-enable them in the same Privacy & Security lists. The app finds its config through the folder it was built in, so if you move or rename this folder, run `make app && make install` from the new location (`make doctor` flags it). The "Finish up" and "Lock up" voice commands, which talk to your open terminals, ask for Automation access when first used, and the control center's Today tab asks for Calendar access.

## License

MIT, see [LICENSE](LICENSE). Bundled fonts (DM Sans, Instrument Serif, JetBrains Mono) are SIL OFL, with their licenses in `app/Resources/Fonts`. The orb geometry is ported from thinking-orbs (MIT), license in `app/ThirdParty`.

Made by [GoldWare](https://goldware.io).
