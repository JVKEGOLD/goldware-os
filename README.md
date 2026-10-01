<p align="center"><img src="app/Resources/goldware-logo.png" alt="GoldWare OS" width="160"></p>

# GoldWare OS

Your Mac, voice, vision, and a dashboard you reshape with your own AI. Everything runs locally.

- **Voice**: push-to-talk dictation and a voice assistant (whisper.cpp for speech, a local Ollama model for cleanup and understanding).
- **Vision**: Mac camera hand tracking (Apple Vision framework): hand mirror, pointer control, document scan.
- **Dashboard**: a local page at http://127.0.0.1:4188 that you customize by asking your AI agent.

## What you need

- An Apple Silicon Mac (M1 or newer) on macOS 14 or newer
- 16 GB of memory recommended (8 GB works with a smaller model)
- About 15 GB of free disk space
- An internet connection for the first install (after that, everything runs offline)

Setup installs everything else for you.

## Install (about 20 to 40 minutes, mostly downloads)

Open **Terminal** (press Cmd+Space, type Terminal, press Return) and paste these one at a time.

**1. Get the code**

```sh
git clone https://github.com/JVKEGOLD/goldware-os.git ~/goldware-os
```

On a brand-new Mac this opens a box asking to install the "command line developer tools". Click **Install**, wait for it to finish, then paste the command again.

> While the repository is private you need to be signed in to GitHub: install [Homebrew](https://brew.sh), then run `brew install gh`, `gh auth login` (choose GitHub.com, HTTPS, log in with a web browser), and `gh repo clone JVKEGOLD/goldware-os ~/goldware-os` instead of the `git clone` line.

**2. Run setup**

```sh
cd ~/goldware-os
make setup
```

Setup checks your Mac, installs what is missing, downloads the speech and language models, builds the app, and asks before copying it to your Applications folder (type `y` and press Return). It is safe to run again at any time.

If setup stops, it prints exactly what to do next (for example the one-line command to install Homebrew). Do that, then run `make setup` again; it picks up where it left off.

**3. Open the app**

Open **GoldWare OS** from your Applications folder. Because it is not from the App Store, macOS blocks the first launch: right-click the app and choose **Open**, or go to System Settings > Privacy & Security and click **Open Anyway**.

Then allow these when asked (or turn them on in System Settings > Privacy & Security):

| Permission | What it is for |
|---|---|
| Microphone | dictation and the assistant |
| Accessibility | pasting text and global hotkeys |
| Speech Recognition | the "Hey GoldWare" wake phrase |
| Camera | Vision (hand tracking, document scan) |

That's it. Say **"Hey GoldWare"**, and open your dashboard at http://127.0.0.1:4188.

**Keep the `~/goldware-os` folder where it is.** The app reads its settings and dashboard from it.

### Prefer to let an AI do it?

If you use an AI coding agent (Claude Code, Codex, Hermes, ...), open it in the `goldware-os` folder after step 1 and paste in [MASTER_PROMPT.md](MASTER_PROMPT.md). It runs setup, explains each step, and asks before installing anything. You still do step 3 yourself.

## Updating

```sh
cd ~/goldware-os
git pull
make setup
```

Setup skips what is already done and rebuilds the app. After an update macOS may forget the app's permissions (see Troubleshooting).

## Troubleshooting

Run this first. It checks every piece and prints the fix for anything missing:

```sh
make doctor
```

- **Voice or camera stopped working after an update.** The app is not signed with an Apple developer certificate, so macOS can forget its permissions after a rebuild. In System Settings > Privacy & Security, open Microphone, Accessibility, Speech Recognition, and Camera, remove GoldWare OS if it is listed (the minus button), and turn it back on.
- **"GoldWare OS can't be opened".** Right-click the app and choose Open, or System Settings > Privacy & Security > Open Anyway.
- **You moved or renamed the `goldware-os` folder.** Run `make setup` again from the new location.
- **A download failed or was interrupted.** Run `make setup` again; downloads resume.
- **Still stuck?** Copy everything setup printed and paste it into your AI agent, or open an issue.

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

## Other permissions

The "Finish up" and "Lock up" voice commands, which talk to your open terminals, ask for Automation access the first time you use them, and the control center's Today tab asks for Calendar access. Allow them only if you want those features.

## License

MIT, see [LICENSE](LICENSE). Bundled fonts (DM Sans, Instrument Serif, JetBrains Mono) are SIL OFL, with their licenses in `app/Resources/Fonts`. The orb geometry is ported from thinking-orbs (MIT), license in `app/ThirdParty`.

Made by [GoldWare](https://goldware.io).
