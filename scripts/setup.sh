#!/bin/zsh
# GoldWare OS installer. Idempotent: safe to rerun.
#   scripts/setup.sh [--dry-run] [--yes] [--open] [--agent claude|codex] [--only STEP]
# Steps (11): platform clt brew packages (whisper-cpp, ollama, iTerm2, JetBrains Mono Nerd Font)
#   iterm-profile (GoldWare profile for Let's work) memory config agent (Claude or Codex; installs and signs in Hermes) pull whisper build install
set -uo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT" || exit 1

DRY=0; YES=0; OPEN=0; ONLY=""; AGENT=""
while (( $# )); do
  case "$1" in
    --dry-run) DRY=1 ;;
    --yes|-y) YES=1 ;;
    --open) OPEN=1 ;;
    --only) shift; ONLY="${1:-}" ;;
    --only=*) ONLY="${1#--only=}" ;;
    --agent) shift; AGENT="${1:-}" ;;
    --agent=*) AGENT="${1#--agent=}" ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)"; exit 2 ;;
  esac
  shift
done
[[ -z "$AGENT" || "$AGENT" == claude || "$AGENT" == codex ]] || { echo "--agent must be claude or codex"; exit 2; }

APP_SRC="$ROOT/app/build/GoldWareOS.app"
APP_DST="/Applications/GoldWare OS.app"
DATA_DIR="$HOME/Library/Application Support/GoldWare OS"
MODEL_DIR="$DATA_DIR/models"
WHISPER_FILE="ggml-small.en-q5_1.bin"
WHISPER_MIN=190000000   # real file is 190098681 bytes; anything smaller is a partial download
WHISPER_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$WHISPER_FILE"
BREW_INSTALL='/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'

# Homebrew may not be on PATH in a fresh shell.
for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
  [[ -x "$b" ]] && eval "$("$b" shellenv)" && break
done

step() { print -P "\n%B==> $1%b"; }
ok()   { print -P "  %F{green}OK%f   $1"; }
skip() { print -P "  %F{yellow}SKIP%f $1"; }
would(){ print -P "  %F{cyan}DRY%f  would: $1"; }
fail() { print -P "  %F{red}FAIL%f $1" >&2; shift; for l in "$@"; do print "       $l" >&2; done; exit 1; }
run()  { if (( DRY )); then would "$*"; else "$@"; fi; }

# ask "question": yes with --yes, no in dry-run, else prompt.
ask() {
  (( YES )) && return 0
  (( DRY )) && return 1
  [[ -t 0 ]] || return 1
  local a; read -r "a?  $1 [y/N] " ; [[ "$a" == [yY]* ]]
}

want() { [[ -z "$ONLY" || "$ONLY" == "$1" ]]; }

(( DRY )) && print "DRY RUN: nothing will be installed, downloaded, built, or copied."

step_platform() {
  step "1/11 Check Mac (Apple Silicon, macOS 14+)"
  # hw.optional.arm64 is 1 on Apple Silicon even in a Rosetta terminal, where uname -m says x86_64.
  [[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" == "1" ]] || fail "This Mac is not Apple Silicon ($(uname -m))." \
    "GoldWare OS needs an Apple Silicon Mac (M1 or newer)."
  local v major; v="$(sw_vers -productVersion)"; major="${v%%.*}"
  (( major >= 14 )) || fail "macOS $v is too old." "Update to macOS 14 or newer in System Settings > General > Software Update."
  ok "Apple Silicon, macOS $v"
  # Models and builds need roughly 10 GB. Warn, do not block: the user may know better.
  local free_kb; free_kb="$(df -k "$HOME" 2>/dev/null | awk 'NR==2{print $4}')"
  if [[ -n "$free_kb" ]] && (( free_kb < 10485760 )); then
    print -P "  %F{yellow}WARN%f only $(( free_kb / 1048576 )) GB free. The language model, speech model and build need about 10 GB." >&2
    print "       Free some space first (Apple menu > System Settings > General > Storage), or the downloads may fail." >&2
  else
    ok "$(( ${free_kb:-0} / 1048576 )) GB free disk"
  fi
}

step_clt() {
  step "2/11 Apple Command Line Tools (not Xcode), swift, python3"
  if ! xcode-select -p >/dev/null 2>&1; then
    if (( DRY )); then would "xcode-select --install, then ask you to rerun"; return; fi
    xcode-select --install >/dev/null 2>&1
    fail "Command Line Tools were not installed." \
      "A system dialog just opened. Click Install, wait for it to finish, then rerun: scripts/setup.sh"
  fi
  ok "Command Line Tools at $(xcode-select -p)"
  # After a macOS update the tools can be present but stale; swift then errors out.
  swift --version >/dev/null 2>&1 || fail "swift is missing or broken." \
    "Run: xcode-select --install   (if it says already installed, update 'Command Line Tools' in System Settings > General > Software Update)"
  command -v python3 >/dev/null 2>&1 || fail "python3 not found." "Run: xcode-select --install"
  ok "swift and python3 present"
}

step_brew() {
  step "3/11 Homebrew"
  if command -v brew >/dev/null 2>&1; then ok "brew $(brew --version | head -1)"; return; fi
  if (( DRY )); then would "ask to install Homebrew with: $BREW_INSTALL"; return; fi
  if ask "Homebrew (the Mac package manager) is missing. Install it now? It will ask for your Mac password."; then
    print "  Installing Homebrew (official installer)..."
    if (( YES )); then export NONINTERACTIVE=1; fi
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
      || fail "Homebrew install failed." "Run it yourself: $BREW_INSTALL"
    for b in /opt/homebrew/bin/brew; do [[ -x "$b" ]] && eval "$("$b" shellenv)"; done
    command -v brew >/dev/null 2>&1 || fail "brew still not on PATH." "Open a new terminal and rerun scripts/setup.sh"
    ok "Homebrew installed"
  else
    fail "Homebrew is not installed." \
      "Install it with the official command (it may ask for your password):" \
      "  $BREW_INSTALL" \
      "Then rerun: scripts/setup.sh   (or rerun with --yes to let this script do it)"
  fi
}

# Where iTerm2 is installed, if anywhere (/Applications, ~/Applications, or wherever Spotlight finds it).
iterm_app() {
  local a
  for a in /Applications/iTerm.app "$HOME/Applications/iTerm.app"; do [[ -d "$a" ]] && { print -r -- "$a"; return; }; done
  mdfind "kMDItemCFBundleIdentifier == 'com.googlecode.iterm2'" 2>/dev/null | head -1
}

step_packages() {
  step "4/11 whisper-cpp, ollama, iTerm2 and the terminal font"
  local f
  for f in whisper-cpp ollama; do
    local bin="$f"; [[ "$f" == whisper-cpp ]] && bin=whisper-server
    if command -v "$bin" >/dev/null 2>&1 || { command -v brew >/dev/null 2>&1 && brew list --formula "$f" >/dev/null 2>&1; }; then
      skip "$f already installed"
    else
      if (( DRY )); then would "brew install $f"; else
        brew install "$f" || fail "brew install $f failed." "Run: brew doctor, fix what it reports, then rerun."
        hash -r
        [[ "$bin" == whisper-server ]] && ! command -v whisper-server >/dev/null 2>&1 \
          && fail "whisper-cpp installed but whisper-server is not on PATH." "Run: brew link whisper-cpp   or   brew reinstall whisper-cpp"
        ok "$f installed"
      fi
    fi
  done
  # iTerm2 (what Let's work opens) and its font. Casks: skipped when already present.
  if [[ -n "$(iterm_app)" ]] || { command -v brew >/dev/null 2>&1 && brew list --cask iterm2 >/dev/null 2>&1; }; then
    skip "iTerm2 already installed"
  elif (( DRY )); then would "brew install --cask iterm2"
  else
    brew install --cask iterm2 || fail "brew install --cask iterm2 failed." "Run: brew doctor, fix what it reports, then rerun."
    ok "iTerm2 installed"
  fi
  if ls ~/Library/Fonts /Library/Fonts 2>/dev/null | grep -qi JetBrainsMonoNerd || { command -v brew >/dev/null 2>&1 && brew list --cask font-jetbrains-mono-nerd-font >/dev/null 2>&1; }; then
    skip "JetBrains Mono Nerd Font already installed"
  elif (( DRY )); then would "brew install --cask font-jetbrains-mono-nerd-font"
  else
    brew install --cask font-jetbrains-mono-nerd-font || fail "brew install --cask font-jetbrains-mono-nerd-font failed." "Run: brew doctor, then rerun."
    ok "JetBrains Mono Nerd Font installed"
  fi
  if curl -fsS --max-time 2 http://127.0.0.1:11434/ >/dev/null 2>&1; then
    skip "ollama already answering on 127.0.0.1:11434"
  elif (( DRY )); then
    would "brew services start ollama"
  else
    brew services start ollama >/dev/null 2>&1 || true
    local i
    for i in {1..20}; do
      curl -fsS --max-time 2 http://127.0.0.1:11434/ >/dev/null 2>&1 && break
      sleep 1
    done
    curl -fsS --max-time 2 http://127.0.0.1:11434/ >/dev/null 2>&1 \
      && ok "ollama started" \
      || fail "ollama is not answering on 127.0.0.1:11434." "Try: brew services restart ollama   or run: ollama serve"
  fi
}

step_iterm_profile() {
  step "5/11 GoldWare iTerm profile"
  local src="$ROOT/app/Resources/iTerm/goldware-profile.json"
  local dstdir="$HOME/Library/Application Support/iTerm2/DynamicProfiles" dst
  dst="$dstdir/goldware.json"
  [[ -f "$src" ]] || fail "Missing $src." "Run: git pull"
  if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then skip "profile already installed at $dst"; return; fi
  # A profile the user changed (font, colors) is theirs: an update never puts the stock one back.
  if [[ -f "$dst" ]]; then skip "kept your GoldWare iTerm profile (it differs from the stock one). Stock copy: $src"; return; fi
  if (( DRY )); then would "copy app/Resources/iTerm/goldware-profile.json to \"$dst\" (adds a GoldWare profile; your other profiles are not touched)"; return; fi
  mkdir -p "$dstdir" && cp "$src" "$dst" || fail "Could not install the iTerm profile." "Copy $src to $dst by hand."
  ok "GoldWare profile added to iTerm (Dynamic Profile, your default profile is unchanged)"
}

TIER=""; MODEL=""
pick_tier() {
  [[ -n "$MODEL" ]] && return
  local bytes gb; bytes="$(sysctl -n hw.memsize)"; gb=$(( bytes / 1073741824 ))
  if (( gb < 12 )); then TIER=small; MODEL="gemma4:e2b"
  elif (( gb < 28 )); then TIER=standard; MODEL="gemma4:e4b"
  else
    TIER=large; MODEL="gemma4:e4b"
    if [[ "${GOLDWARE_TIER:-}" == "large" ]] && (( YES )); then MODEL="gemma4:12b"
    elif ask "This Mac has ${gb} GB. Use the larger gemma4:12b model (more accurate, about 8 GB download)?"; then MODEL="gemma4:12b"
    fi
  fi
  MEM_GB="$gb"
}

step_memory() {
  step "6/11 Pick a model for this Mac's memory"
  pick_tier
  case "$TIER" in
    small) ok "tier small (${MEM_GB} GB RAM): $MODEL, the lightest model that leaves room for macOS" ;;
    standard) ok "tier standard (${MEM_GB} GB RAM): $MODEL, best balance of speed and quality" ;;
    large) ok "tier large (${MEM_GB} GB RAM): $MODEL ($( [[ $MODEL == *12b ]] && echo 'larger model chosen' || echo 'default kept; set GOLDWARE_TIER=large with --yes, or answer yes, for gemma4:12b'))" ;;
  esac
}

step_config() {
  step "7/11 goldware.json"
  pick_tier
  if [[ ! -f goldware.json ]]; then
    if (( DRY )); then would "create goldware.json from goldware.default.json with models.local = $MODEL"; return; fi
    cp goldware.default.json goldware.json || fail "Could not create goldware.json."
    GW_MODEL="$MODEL" python3 - <<'PY' || fail "Could not edit goldware.json."
import json, os
p = "goldware.json"
c = json.load(open(p))
c.setdefault("models", {})["local"] = os.environ["GW_MODEL"]
open(p, "w").write(json.dumps(c, indent=2) + "\n")
PY
    ok "created goldware.json with models.local = $MODEL"
    FRESH=1
    return
  fi
  local cur
  cur="$(python3 -c 'import json;print(json.load(open("goldware.json")).get("models",{}).get("local",""))' 2>/dev/null)" \
    || fail "goldware.json exists but is not valid JSON." "Fix it, or move it aside and rerun: mv goldware.json goldware.json.broken"
  if [[ "$cur" == "$MODEL" ]]; then skip "goldware.json already uses $MODEL"; return; fi
  if (( DRY )); then would "offer to change models.local from '$cur' to '$MODEL' (only that field)"; return; fi
  if ask "goldware.json uses model '$cur'. Change models.local to '$MODEL' for this Mac? (nothing else is touched)"; then
    cp goldware.json goldware.json.bak
    GW_MODEL="$MODEL" python3 - <<'PY' || fail "Could not edit goldware.json." "Backup is goldware.json.bak"
import json, os
p = "goldware.json"
c = json.load(open(p))
c.setdefault("models", {})["local"] = os.environ["GW_MODEL"]
open(p, "w").write(json.dumps(c, indent=2) + "\n")
PY
    ok "models.local set to $MODEL (backup: goldware.json.bak)"
  else
    skip "kept your models.local = $cur"
    MODEL="$cur"
  fi
}

# What Let's work runs in its four windows. Claude needs a Claude plan that Hermes can use; Codex
# runs on a ChatGPT plan. Asked once, on a new goldware.json; later: --only agent [--agent X].
# Then makes sure Hermes itself is installed and signed in, since Let's work opens it.
CLAUDE_CMD="hermes -m claude-opus-5-5 --provider anthropic"
CODEX_CMD="hermes -m gpt-5.5 --provider openai-codex"
HERMES_INSTALL="curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --skip-setup"
FRESH=0
step_agent() {
  step "7b/11 Hermes agent for Let's work (Claude or Codex)"
  if [[ -z "$AGENT" ]] && { (( FRESH )) || [[ "$ONLY" == agent ]]; }; then
    if (( DRY )); then would "ask whether Let's work runs Hermes on Claude or Codex"
    elif (( ! YES )) && [[ -t 0 ]]; then
      local a; read -r "a?  Let's work opens Hermes agents. Use 1) Claude or 2) Codex (ChatGPT plan)? [1/2] "
      case "$a" in 1|[cC]laude) AGENT=claude ;; 2|[cC]odex) AGENT=codex ;; esac
    fi
  fi
  if [[ -n "$AGENT" ]]; then
    local cmd="$CLAUDE_CMD"; [[ "$AGENT" == codex ]] && cmd="$CODEX_CMD"
    if (( DRY )); then would "set letsWork.command to '$cmd' in goldware.json"
    else
      [[ -f goldware.json ]] || fail "goldware.json is missing." "Run: scripts/setup.sh --only config"
      (( FRESH )) || cp goldware.json goldware.json.bak
      GW_CMD="$cmd" python3 - <<'PY' || fail "Could not edit goldware.json." "Backup is goldware.json.bak"
import json, os
p = "goldware.json"
c = json.load(open(p))
c.setdefault("letsWork", {})["command"] = os.environ["GW_CMD"]
open(p, "w").write(json.dumps(c, indent=2) + "\n")
PY
      ok "Let's work runs: $cmd"
    fi
  fi
  # Which provider the configured command uses (also for a goldware.json set up earlier).
  local cfg=goldware.json; [[ -f $cfg ]] || cfg=goldware.default.json
  local cur; cur="$(python3 -c "import json;print(json.load(open('$cfg')).get('letsWork',{}).get('command','$CLAUDE_CMD'))" 2>/dev/null)"
  [[ "$cur" == hermes* ]] || { skip "Let's work does not run Hermes ('${cur:-plain shell}'), so Hermes is not needed"; return; }
  local provider=anthropic login="hermes auth add anthropic --type oauth" plan="Claude"
  [[ "$cur" == *openai-codex* ]] && provider=openai-codex login="hermes auth add openai-codex" plan="ChatGPT (Codex)"

  # Hermes installs to ~/.local/bin, which a fresh shell may not have on PATH yet.
  [[ ":$PATH:" == *":$HOME/.local/bin:"* ]] || export PATH="$HOME/.local/bin:$PATH"
  if command -v hermes >/dev/null 2>&1; then
    skip "Hermes already installed at $(command -v hermes)"
  elif (( DRY )); then would "ask to install Hermes with: $HERMES_INSTALL"; return
  elif ask "Hermes (the AI agent Let's work opens) is not installed. Install it now with its official installer? About 2 minutes, no password needed."; then
    zsh -c "$HERMES_INSTALL" || fail "Hermes install failed." "Rerun it by hand: $HERMES_INSTALL" "Then: scripts/setup.sh --only agent"
    command -v hermes >/dev/null 2>&1 || fail "Hermes installed but 'hermes' is not on PATH." "Open a new terminal window, then rerun: scripts/setup.sh --only agent"
    ok "Hermes installed at $(command -v hermes)"
  else
    skip "Hermes not installed. Install later: $HERMES_INSTALL"; return
  fi

  if hermes auth status "$provider" 2>/dev/null | grep -q "logged in"; then
    skip "Hermes is already signed in to $plan"
  elif [[ -t 0 ]] && ask "Sign Hermes in to your $plan plan now? A browser window opens."; then
    $=login || fail "Sign-in did not finish." "Rerun: $login"
    ok "Hermes signed in to $plan"
  else
    skip "Hermes is not signed in yet. Run once: $login"
  fi
}

step_pull() {
  step "8/11 Pull the language model"
  pick_tier
  if [[ -f goldware.json ]]; then
    local cfg; cfg="$(python3 -c 'import json;print(json.load(open("goldware.json")).get("models",{}).get("local",""))' 2>/dev/null)"
    [[ -n "$cfg" ]] && MODEL="$cfg"
  fi
  if command -v ollama >/dev/null 2>&1 && curl -fsS --max-time 2 http://127.0.0.1:11434/ >/dev/null 2>&1 \
     && ollama list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$MODEL"; then
    skip "$MODEL already pulled"; return
  fi
  if (( DRY )); then would "ollama pull $MODEL"; return; fi
  command -v ollama >/dev/null 2>&1 || fail "ollama not installed." "Run: brew install ollama"
  ollama pull "$MODEL" || fail "ollama pull $MODEL failed." "Check your network and that ollama is running (brew services start ollama), then rerun."
  ok "$MODEL ready"
}

step_whisper() {
  step "9/11 Whisper speech model ($WHISPER_FILE)"
  local f="$MODEL_DIR/$WHISPER_FILE" size=0
  [[ -f "$f" ]] && size="$(stat -f%z "$f")"
  if (( size > WHISPER_MIN )); then skip "already present ($(( size / 1048576 )) MB)"; return; fi
  if (( DRY )); then would "download $WHISPER_URL to $MODEL_DIR (about 180 MB)"; return; fi
  mkdir -p "$MODEL_DIR"
  # Download to a .part file and rename only when complete, so an interrupted
  # download (Ctrl-C, Wi-Fi drop) is never mistaken for a finished model. Rerun resumes.
  local part="$f.part"
  curl -L --fail -C - --progress-bar -o "$part" "$WHISPER_URL" \
    || fail "Whisper model download failed." "Rerun to resume, or download it by hand: curl -L --fail -C - -o \"$part\" $WHISPER_URL"
  size="$(stat -f%z "$part")"
  (( size > WHISPER_MIN )) || fail "Downloaded file is too small ($size bytes)." "Delete \"$part\" and rerun."
  mv -f "$part" "$f" || fail "Could not move the model into place."
  ok "downloaded ($(( size / 1048576 )) MB)"
}

step_build() {
  step "10/11 Build the app"
  if (( DRY )); then would "(cd app && ./build.sh) -> app/build/GoldWareOS.app"; return; fi
  (cd app && ./build.sh) || fail "App build failed." \
    "Read the swift error above. Common fix: xcode-select --install, or sudo xcode-select -s /Library/Developer/CommandLineTools" \
    "then rerun: make app"
  [[ -d "$APP_SRC" ]] || fail "Build finished but $APP_SRC is missing."
  ok "built app/build/GoldWareOS.app"
}

step_install() {
  step "11/11 Install to /Applications"
  if (( DRY )); then would "copy app/build/GoldWareOS.app to \"$APP_DST\" (asks first unless --yes)"; return; fi
  [[ -d "$APP_SRC" ]] || fail "No built app at app/build/GoldWareOS.app." "Run: make app"
  if [[ -e "$APP_DST" ]]; then
    local bid; bid="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_DST/Contents/Info.plist" 2>/dev/null)"
    [[ "$bid" == "io.goldware.os" ]] || fail "\"$APP_DST\" exists and is not GoldWare OS (id: ${bid:-unknown})." "Not touching it. Move or rename it, then rerun."
  fi
  if ! ask "Copy GoldWare OS to /Applications?"; then skip "not installed. Run later: make install"; return; fi
  if pgrep -x GoldWareOS >/dev/null 2>&1; then
    print "  GoldWare OS is running; asking it to quit..."
    osascript -e 'tell application id "io.goldware.os" to quit' >/dev/null 2>&1 || true
    local i; for i in {1..10}; do pgrep -x GoldWareOS >/dev/null 2>&1 || break; sleep 1; done
    pgrep -x GoldWareOS >/dev/null 2>&1 && pkill -x GoldWareOS 2>/dev/null; sleep 1
    pgrep -x GoldWareOS >/dev/null 2>&1 && fail "GoldWare OS would not quit." "Quit it from the menu bar, then rerun: make install"
  fi
  # Copy next to the target first, then swap, so a failed copy never leaves /Applications without the app.
  local tmp="$APP_DST.installing"
  rm -rf "$tmp"
  cp -R "$APP_SRC" "$tmp" || { rm -rf "$tmp"; fail "Copy to /Applications failed." "Check permissions on /Applications and free disk space."; }
  rm -rf "$APP_DST" && mv "$tmp" "$APP_DST" || fail "Could not replace $APP_DST." "Check permissions on /Applications."
  ok "installed to $APP_DST"
  if (( OPEN )) || ask "Open GoldWare OS now?"; then open "$APP_DST"; ok "opened"; fi
}

next_steps() {
  cat <<'TXT'

Next steps
  1. Open GoldWare OS from /Applications (first launch of an ad-hoc signed app:
     right-click > Open, or System Settings > Privacy & Security > Open Anyway).
  2. Grant permissions when asked (System Settings > Privacy & Security):
       Microphone          dictation and the assistant
       Accessibility       pasting text and global hotkeys
       Speech Recognition  the wake phrase
       Camera              Vision (hand tracking, document scan)
  3. Dashboard: http://127.0.0.1:4188
  4. Check everything: make doctor
TXT
}

if [[ -n "$ONLY" ]]; then
  case "$ONLY" in platform|clt|brew|packages|iterm-profile|memory|config|agent|pull|whisper|build|install) ;;
    *) echo "Unknown step '$ONLY'. Steps: platform clt brew packages iterm-profile memory config agent pull whisper build install"; exit 2 ;;
  esac
  step_platform
  want platform || "step_${ONLY//-/_}"
  (( DRY )) || [[ "$ONLY" != install ]] || next_steps
  exit 0
fi

step_platform; step_clt; step_brew; step_packages; step_iterm_profile; step_memory
step_config; step_agent; step_pull; step_whisper; step_build; step_install
if (( DRY )); then print -P "\n%F{green}Dry run complete. Nothing was changed.%f"; exit 0; fi
print -P "\n%F{green}Setup finished.%f"
next_steps
