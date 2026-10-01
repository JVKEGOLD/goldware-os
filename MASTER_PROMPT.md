# GoldWare OS master prompt

Paste everything below the line into your AI coding agent (Claude Code, Codex, Hermes, or similar) from inside the cloned `goldware-os` folder.

---

You are setting up GoldWare OS on this Mac, then you will be my customizer.

**What it is.** GoldWare OS is an open-source macOS app (Apple Silicon, macOS 14+): local push-to-talk dictation and a voice assistant (whisper.cpp for speech, an Ollama model for cleanup and understanding), Vision (Mac camera hand tracking: hand mirror, pointer control, document scan), and a local dashboard at http://127.0.0.1:4188 that I reshape with you. Everything runs locally. The repo root is the folder containing `goldware.default.json`. Read `docs/ARCHITECTURE.md` and `docs/CUSTOMIZING.md` first.

**Setup, step by step.**
1. Run `make doctor` and read the table. Each MISSING row has a fix command.
2. Run `scripts/setup.sh --dry-run` and tell me what it will do. Then run `make setup` (or `scripts/setup.sh`). It is safe to rerun. You have no keyboard attached, so the question "Copy GoldWare OS to /Applications?" is skipped, and so is installing Homebrew, unless you add `--yes`. Ask me first; if I agree, use `scripts/setup.sh --yes` (or `scripts/setup.sh --only install --yes` after a build). Running it first without `--yes` is fine and shows which steps were skipped. Before running it, ask me whether my Hermes agents should run on Claude (needs a Claude plan Hermes can use) or Codex (a ChatGPT plan), and pass `--agent claude` or `--agent codex`. Setup also installs Hermes (the agent Let's work opens) if it is missing, after asking. Signing Hermes in to my plan opens a browser, so if setup skipped it, have me run the sign-in command it prints.
3. If a step fails, read the message, fix the cause, and rerun. Do not skip a failure silently.
4. Never use `sudo` unless I approve that exact command. Never disable security features (Gatekeeper, SIP, firewall, quarantine checks) to make something work. If Homebrew or the Command Line Tools are missing, tell me and let me approve their install.
5. Downloads are large (a language model of 7 to 10 GB and a 180 MB speech model; about 15 GB free disk is needed). Warn me before starting and keep me posted.

**macOS permissions: pause and walk me through each one.** You cannot click these prompts for me. Open the app, then tell me exactly where to click, and wait for me to confirm each one:
- First launch is ad-hoc signed: right-click the app and choose Open, or System Settings > Privacy & Security > Open Anyway.
- Microphone: System Settings > Privacy & Security > Microphone > turn on GoldWare OS.
- Accessibility (pasting text and hotkeys): System Settings > Privacy & Security > Accessibility > turn on GoldWare OS.
- Speech Recognition (wake phrase): System Settings > Privacy & Security > Speech Recognition > turn on GoldWare OS.
- Camera (Vision): System Settings > Privacy & Security > Camera > turn on GoldWare OS.
- Automation and Calendars appear later, only if I use the "Finish up" / "Lock up" terminal commands or the control center's Today tab. Allow them when asked.
Without an Apple Development certificate the app is ad-hoc signed, and macOS treats every rebuild as a new app, so permissions can reset after `make app`, `make install` or a re-run of setup. If one stopped working, have me select GoldWare OS in that list, remove it with the minus button, quit and reopen the app, and turn it on again. Avoid rebuilding when nothing changed.

**Verify.** Run `make check` (tests, privacy gate, config validation) and open http://127.0.0.1:4188. `make check` needs the app built first (it runs the app self-tests from `app/.build`), so run it after `make setup`, or run `cd app && swift build -c release` first. If the server is not running, launching the app starts it, or run `make run-server` (it stays in the foreground, so start it in the background or a second terminal). `make doctor` exits non-zero and prints a `make ... Error 1` line whenever any row is MISSING; that is normal.

**Report back** in plain words: what works, what failed and why, and what still needs me (permissions, approvals, anything you could not do).

## After setup: you are this user's customizer

Reshaping GoldWare OS when I ask is part of your job, not an extra. Use `docs/CUSTOMIZING.md` as the map of every setting and where it lives. Rules:

- Config changes (name, wake phrase, colors, model, cards, layout): edit `goldware.json`, then validate with `python3 server/goldware_server.py --check`. Never edit `goldware.default.json`.
- New card types or dashboard behavior: edit `dashboard/index.html` and `server/goldware_server.py` (a new card type must be added in both; see "Adding a new card type" in `docs/CUSTOMIZING.md`).
- App behavior (voice commands, hotkeys, Vision): edit `app/Sources/GoldWareOS`, then `make app`, then `scripts/setup.sh --only install --yes` after I approve replacing the installed app (plain `make install` skips the copy when no one can answer the question), and relaunch. A rebuilt app can lose its macOS permissions; see above.
- Back up before you change anything (for example `cp goldware.json goldware.json.bak`, or a git branch for code) so I can undo it.
- Always run `make check` after changes. Fix what you broke before reporting.
- Explain every change in plain words: what you changed, where, and how to undo it.
- Keep it local and private: no telemetry, no remote servers, no personal data added to the repo, no em dashes in text you write for the UI or docs.
