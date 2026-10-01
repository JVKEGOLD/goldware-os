<p align="center"><img src="app/Resources/goldware-logo.png" alt="GoldWare OS" width="160"></p>

# GoldWare OS

Your Mac, voice, vision, and a dashboard you reshape with your own AI. Everything runs locally.

- **Voice**: push-to-talk dictation and a voice assistant (whisper.cpp for speech, a local Ollama model for cleanup and understanding).
- **Vision**: Mac camera hand tracking (Apple Vision framework): hand mirror, pointer control, document scan.
- **Office**: every Hermes, Claude Code, Codex and Ollama running on this Mac, each at a pixel-art desk with a short name and its chat title. Click one to read its terminal and type to it, see what it needs from you, keep a task board, and watch your plan usage. Empty if you run none of them.
- **Dashboard**: a local page at http://127.0.0.1:4188 that you customize by asking your AI agent.

## What you need

- An Apple Silicon Mac (M1 or newer) on macOS 14 or newer
- 16 GB of memory recommended (8 GB works with a smaller model)
- About 15 GB of free disk space
- An internet connection for the first install (after that, everything runs offline)

Setup installs everything else for you (Homebrew, the speech engine, the local AI model, iTerm2, and the JetBrains Mono Nerd Font). It also adds a **GoldWare** profile to iTerm for the Let's work terminals; this sits alongside iTerm's default profile and does not replace it or change your other profiles. It also installs **Hermes**, the AI agent the Let's work terminals open, and asks whether it should run on **Claude** or **Codex** (a ChatGPT plan). Hermes is the only part that needs an account: you sign it in to your Claude or ChatGPT plan once, in the browser window setup opens. Everything else needs no account.

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

Answer the questions it asks: type `y` and press Return (for Claude or Codex, type `1` or `2`). When it asks for your password, type your Mac login password (it stays hidden while you type) and press Return. You can leave it running while it downloads.

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
cd ~/goldware-os && make update
```

**First update from an older copy?** If `make update` says there is no rule to make target `update`, your copy is from before it existed. Run this once, then use `make update` from then on:

```sh
cd ~/goldware-os && git pull && make setup
```

**`make update` and `git pull` are not the same.** `git pull` only downloads the new code: it does not rebuild the app (you still need `make setup`), and it can stop partway if you or your AI changed the same files. `make update` does all of it: it saves your own code changes first, downloads the update and merges it on top, stops without changing anything if the two clash, then runs setup to rebuild.

Your setup survives every update. Your settings (`goldware.json`: name, wake phrase, colors, model, dashboard cards, which agent Let's work opens) and your data (`data/`) are not part of the download, so an update never touches them. Changes you or your AI made to the code are saved as your own commit first, and the update is merged in on top. If an update edits the same lines you changed, nothing is changed and it tells you what to ask your AI. Then setup skips what is already done and rebuilds the app. After an update macOS may forget the app's permissions (see Troubleshooting).

## Uninstalling

Quit GoldWare OS first (menu bar icon, then Quit). If you turned on Open at Login, turn it off in the app first, or remove it later in System Settings > General > Login Items.

1. Remove the app and everything it stores on this Mac (history, recordings, the speech model, Face ID, settings):

```sh
osascript -e 'tell application id "io.goldware.os" to quit'
tccutil reset All io.goldware.os
rm -rf "/Applications/GoldWare OS.app"
rm -rf "$HOME/Library/Application Support/GoldWare OS"
rm -rf "$HOME/Library/Caches/io.goldware.os" "$HOME/Library/WebKit/io.goldware.os" \
       "$HOME/Library/HTTPStorages/io.goldware.os" "$HOME/Library/Saved Application State/io.goldware.os.savedState"
defaults delete io.goldware.os
```

The `tccutil` line clears the camera, microphone, and other permissions you granted. It has to run while the app is still in Applications; if you already deleted it, macOS no longer knows the app and says "No such bundle identifier", which is harmless (the leftover permission entries do nothing). Accessibility may still list GoldWare OS in System Settings > Privacy & Security > Accessibility; select it and click the minus button.

2. Remove the GoldWare iTerm profile (your other iTerm profiles are not touched):

```sh
rm -f "$HOME/Library/Application Support/iTerm2/DynamicProfiles/goldware.json"
```

3. Delete the repo folder. This also deletes your `goldware.json`, tasks, notes, and Office board in `data/`, so copy anything you want to keep first:

```sh
rm -rf ~/goldware-os
```

4. Optional: setup also installed some shared tools that other apps may use. Remove only the ones you don't need:

Run `ollama list` to see the model name setup pulled (`gemma4:e2b`, `gemma4:e4b`, or `gemma4:12b`), then remove it before uninstalling Ollama:

```sh
ollama rm gemma4:e4b
brew services stop ollama
brew uninstall ollama whisper.cpp
brew uninstall --cask iterm2 font-jetbrains-mono-nerd-font
```

If you are removing Ollama completely and no other app uses it, also delete its model folder: `rm -rf ~/.ollama`

Homebrew and Apple's Command Line Tools stay installed; other software often depends on them.

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
| under 12 GB | small | `gemma4:e2b`; AI Cleanup ships off here (the model makes dictation slow on 8 GB). Turn it on from the menu bar icon > AI Cleanup |
| 12 to 28 GB | standard | `gemma4:e4b` |
| 28 GB or more | large | `gemma4:e4b` by default, `gemma4:12b` if you opt in (set `GOLDWARE_TIER=large` with `--yes`, or answer yes when asked) |

## Privacy

Nothing leaves your Mac. Speech, language models, camera frames, tasks, and notes are all processed and stored locally. The plan usage card reads local CLI credentials only to show your own limits. The Office tab only types into a terminal when you press Send, Assign or Talk, and only into a terminal that belongs to an agent it found; the server refuses those requests from any other web page.

## Vision and voice shortcuts

Vision Mode starts locked. Your unlock gesture opens it; praying hands held for under a second lock it again. A thumbs up only files a scan.

| What | Gesture (pointer style) | Voice |
|---|---|---|
| Lock | Praying hands, held | |
| Send what you just dictated | Open hand, swipe quickly to your left (your left as you face the screen). Also works in Quadrants | |
| Let's work | Both hands thumb, index, and middle out, thumbs touching, then pull apart | "Let's work" |
| Lock up | Both hands open, then both fists | "Lock up" |
| Clear out | Both hands open, then one fist | "Clear out" |

Say a voice phrase on its own (optionally after "Hey" or the assistant's name) with Right Command, or after the wake phrase. A task that merely mentions the words stays a task.

- **Let's work** opens one terminal window in each corner of the screen. What each runs comes from `letsWork` in `goldware.json`: `command` (default `hermes`: a Hermes agent on its default model, which setup sets to Claude Opus 5.5 or, for Codex, GPT 5.5; it asks which, and `scripts/setup.sh --only agent --agent codex` switches later. Any window can still change model with `/model`, or `hermes model` changes the default; empty opens a plain shell), `terminal` (`iTerm`), and `profile` (default `GoldWare`, the profile setup installs; if iTerm does not have it, the default profile is used; empty always uses the default profile). The Dashboard's **Shortcuts** card has one-click buttons for Let's work, Lock up and Clear out, the same as the voice phrases and gestures.
- **Lock up** closes every terminal except those with an agent mid-task (a Hermes chat holding a turn lease, or Claude Code or Codex using CPU). If the busy state cannot be read, nothing is closed.
- **Clear out** closes only the Hermes terminals nobody has written in. Without Hermes installed it finds nothing to close.

## Make it yours

GoldWare OS is meant to be reshaped. Rename the assistant, change the wake phrase, add dashboard cards, swap the model, or add voice commands by asking your AI agent. [docs/CUSTOMIZING.md](docs/CUSTOMIZING.md) maps every setting and where it lives.

## Other permissions

The "Let's work", "Finish up", "Lock up", and "Clear out" commands, which talk to your open terminals, ask for Automation access the first time you use them, and the control center's Today tab asks for Calendar access. Allow them only if you want those features.

## License

MIT, see [LICENSE](LICENSE). Bundled fonts (DM Sans, Instrument Serif, JetBrains Mono) are SIL OFL, with their licenses in `app/Resources/Fonts`. The orb geometry is ported from thinking-orbs (MIT), license in `app/ThirdParty`.

Made by [GoldWare](https://goldware.io).
