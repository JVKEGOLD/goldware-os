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

Setup installs everything else for you (Homebrew, the speech engine, and the local AI model). No accounts or sign-ups.

## Install (about 30 minutes, mostly downloads)

You only need Terminal. Open it with Cmd+Space, type **Terminal**, and press Return.

**1. Download GoldWare OS.** Paste this and press Return:

```sh
git clone https://github.com/JVKEGOLD/goldware-os.git ~/goldware-os
```

If a box pops up asking to install "command line developer tools", click **Install**. When it finishes, paste the same line again.

**2. Set it up.** Paste this and press Return:

```sh
cd ~/goldware-os && make setup
```

Answer the questions it asks: type `y` and press Return. When it asks for your password, type your Mac login password (it stays hidden while you type) and press Return. You can leave it running while it downloads.

If it stops with an error, it tells you what to do. Do that, then paste the step 2 line again. It picks up where it left off.

**3. Say yes to permissions.** At the end, setup offers to open GoldWare OS. When macOS asks to allow the Microphone, Accessibility, Speech Recognition, and Camera, allow each one. For Accessibility, macOS opens System Settings: turn on **GoldWare OS** there.

**Done.** Say **"Hey GoldWare"**. Your dashboard is at http://127.0.0.1:4188.

Later you can open GoldWare OS from your Applications folder like any other app. Leave the `goldware-os` folder in your home folder: the app reads its settings from it.

<details>
<summary>What the permissions are for</summary>

| Permission | What it is for |
|---|---|
| Microphone | dictation and the assistant |
| Accessibility | pasting text and global hotkeys |
| Speech Recognition | the "Hey GoldWare" wake phrase |
| Camera | Vision (hand tracking, document scan) |

You can change any of them later in System Settings > Privacy & Security.
</details>

<details>
<summary>While this repository is private</summary>

Step 1 needs you to be signed in to GitHub. First install Homebrew by pasting the install line from https://brew.sh, then run:

```sh
brew install gh
gh auth login
gh repo clone JVKEGOLD/goldware-os ~/goldware-os
```

For `gh auth login`, choose GitHub.com, then HTTPS, then log in with a web browser. Then continue with step 2.
</details>

<details>
<summary>Prefer to let an AI agent do it?</summary>

After step 1, open your AI coding agent (Claude Code, Codex, Hermes, ...) in the `goldware-os` folder and paste in [MASTER_PROMPT.md](MASTER_PROMPT.md). It runs setup, explains each step, and asks before installing anything. You still allow the permissions yourself.
</details>

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
- **"GoldWare OS can't be opened" or "cannot verify the developer".** It is not from the App Store. Right-click the app and choose Open, or go to System Settings > Privacy & Security and click Open Anyway. You only do this once.
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
