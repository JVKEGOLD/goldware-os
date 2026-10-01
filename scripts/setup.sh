#!/bin/zsh
# GoldWare OS installer. Idempotent: safe to rerun.
#   scripts/setup.sh [--dry-run] [--yes] [--open] [--only STEP]
# Steps: platform clt brew packages memory config pull whisper build install
set -uo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT" || exit 1

DRY=0; YES=0; OPEN=0; ONLY=""
while (( $# )); do
  case "$1" in
    --dry-run) DRY=1 ;;
    --yes|-y) YES=1 ;;
    --open) OPEN=1 ;;
    --only) shift; ONLY="${1:-}" ;;
    --only=*) ONLY="${1#--only=}" ;;
    -h|--help) sed -n '2,4p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)"; exit 2 ;;
  esac
  shift
done

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
  step "1/10 Check Mac (Apple Silicon, macOS 14+)"
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
  step "2/10 Xcode Command Line Tools, swift, python3"
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
  step "3/10 Homebrew"
  if command -v brew >/dev/null 2>&1; then ok "brew $(brew --version | head -1)"; return; fi
  if (( DRY )); then would "stop: Homebrew missing. Install with: $BREW_INSTALL"; return; fi
  if (( YES )); then
    print "  Installing Homebrew (official installer, --yes given)..."
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
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

step_packages() {
  step "4/10 whisper-cpp and ollama"
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
  step "5/10 Pick a model for this Mac's memory"
  pick_tier
  case "$TIER" in
    small) ok "tier small (${MEM_GB} GB RAM): $MODEL, the lightest model that leaves room for macOS" ;;
    standard) ok "tier standard (${MEM_GB} GB RAM): $MODEL, best balance of speed and quality" ;;
    large) ok "tier large (${MEM_GB} GB RAM): $MODEL ($( [[ $MODEL == *12b ]] && echo 'larger model chosen' || echo 'default kept; set GOLDWARE_TIER=large with --yes, or answer yes, for gemma4:12b'))" ;;
  esac
}

step_config() {
  step "6/10 goldware.json"
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

step_pull() {
  step "7/10 Pull the language model"
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
  step "8/10 Whisper speech model ($WHISPER_FILE)"
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
  step "9/10 Build the app"
  if (( DRY )); then would "(cd app && ./build.sh) -> app/build/GoldWareOS.app"; return; fi
  (cd app && ./build.sh) || fail "App build failed." \
    "Read the swift error above. Common fix: xcode-select --install, or sudo xcode-select -s /Library/Developer/CommandLineTools" \
    "then rerun: make app"
  [[ -d "$APP_SRC" ]] || fail "Build finished but $APP_SRC is missing."
  ok "built app/build/GoldWareOS.app"
}

step_install() {
  step "10/10 Install to /Applications"
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
  if (( OPEN )); then open "$APP_DST"; ok "opened"; fi
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
  case "$ONLY" in platform|clt|brew|packages|memory|config|pull|whisper|build|install) ;;
    *) echo "Unknown step '$ONLY'. Steps: platform clt brew packages memory config pull whisper build install"; exit 2 ;;
  esac
  step_platform
  want platform || "step_$ONLY"
  (( DRY )) || [[ "$ONLY" != install ]] || next_steps
  exit 0
fi

step_platform; step_clt; step_brew; step_packages; step_memory
step_config; step_pull; step_whisper; step_build; step_install
if (( DRY )); then print -P "\n%F{green}Dry run complete. Nothing was changed.%f"; exit 0; fi
print -P "\n%F{green}Setup finished.%f"
next_steps
