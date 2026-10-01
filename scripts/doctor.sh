#!/bin/zsh
# Read-only health check for GoldWare OS. Changes nothing.
ROOT="${0:A:h:h}"
cd "$ROOT" || exit 1
for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [[ -x "$b" ]] && eval "$("$b" shellenv)" && break; done

BAD=0
row() { # name status detail fix
  if [[ "$2" == OK ]]; then printf "%-26s %-8s %s\n" "$1" "OK" "$3"
  else BAD=$((BAD+1)); printf "%-26s %-8s %s\n" "$1" "MISSING" "$3"; [[ -n "$4" ]] && printf "%-26s %-8s fix: %s\n" "" "" "$4"; fi
}

PORT=4188
[[ -f goldware.json ]] && PORT="$(python3 -c 'import json;print(json.load(open("goldware.json")).get("port",4188))' 2>/dev/null || echo 4188)"
CFG=goldware.json; [[ -f $CFG ]] || CFG=goldware.default.json
MODEL="$(python3 -c "import json;print(json.load(open('$CFG')).get('models',{}).get('local',''))" 2>/dev/null)"
WFILE="$(python3 -c "import json;print(json.load(open('$CFG')).get('models',{}).get('whisper','ggml-small.en-q5_1.bin'))" 2>/dev/null)"
MD="$HOME/Library/Application Support/GoldWare OS/models/$WFILE"

printf "%-26s %-8s %s\n" "CHECK" "STATUS" "DETAIL"
printf "%-26s %-8s %s\n" "-----" "------" "------"

[[ "$(uname -m)" == arm64 ]] && row "Apple Silicon" OK "arm64, macOS $(sw_vers -productVersion)" || row "Apple Silicon" NO "$(uname -m)" "GoldWare OS needs an Apple Silicon Mac"
xcode-select -p >/dev/null 2>&1 && row "Command Line Tools" OK "$(xcode-select -p)" || row "Command Line Tools" NO "" "xcode-select --install"
command -v swift >/dev/null 2>&1 && row "swift" OK "$(command -v swift)" || row "swift" NO "" "xcode-select --install"
command -v python3 >/dev/null 2>&1 && row "python3" OK "$(python3 --version 2>&1)" || row "python3" NO "" "xcode-select --install"
command -v brew >/dev/null 2>&1 && row "Homebrew" OK "$(command -v brew)" || row "Homebrew" NO "" "see https://brew.sh"
command -v whisper-server >/dev/null 2>&1 && row "whisper-server" OK "$(command -v whisper-server)" || row "whisper-server" NO "" "brew install whisper-cpp"
command -v ollama >/dev/null 2>&1 && row "ollama binary" OK "$(command -v ollama)" || row "ollama binary" NO "" "brew install ollama"
if curl -fsS --max-time 2 http://127.0.0.1:11434/ >/dev/null 2>&1; then
  row "ollama answering" OK "127.0.0.1:11434"
  if [[ -n "$MODEL" ]] && ollama list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$MODEL"; then row "model pulled" OK "$MODEL"
  else row "model pulled" NO "${MODEL:-unknown}" "ollama pull ${MODEL:-gemma4:e4b}"; fi
else
  row "ollama answering" NO "nothing on 127.0.0.1:11434" "brew services start ollama"
  row "model pulled" NO "cannot check, ollama is down" "ollama pull ${MODEL:-gemma4:e4b}"
fi
[[ -f "$MD" ]] && (( $(stat -f%z "$MD") > 190000000 )) && row "whisper model file" OK "$MD" || row "whisper model file" NO "$WFILE" "make setup   (downloads to ~/Library/Application Support/GoldWare OS/models/)"
IT_APP="$(for a in /Applications/iTerm.app "$HOME/Applications/iTerm.app"; do [[ -d "$a" ]] && { echo "$a"; break; }; done)"
[[ -z "$IT_APP" ]] && IT_APP="$(mdfind "kMDItemCFBundleIdentifier == 'com.googlecode.iterm2'" 2>/dev/null | head -1)"
[[ -n "$IT_APP" ]] && row "iTerm2" OK "$IT_APP" || row "iTerm2" NO "Let's work opens iTerm windows" "brew install --cask iterm2   (or: make setup)"
{ ls ~/Library/Fonts /Library/Fonts 2>/dev/null | grep -qi JetBrainsMonoNerd; } && row "terminal font" OK "JetBrains Mono Nerd Font" || row "terminal font" NO "JetBrains Mono Nerd Font" "brew install --cask font-jetbrains-mono-nerd-font   (or: make setup)"
ITP="$HOME/Library/Application Support/iTerm2/DynamicProfiles/goldware.json"
[[ -f "$ITP" ]] && row "GoldWare iTerm profile" OK "$ITP" || row "GoldWare iTerm profile" NO "not installed" "scripts/setup.sh --only iterm-profile"
HERMES="$(PATH="$HOME/.local/bin:$PATH" command -v hermes)"
[[ -n "$HERMES" ]] && row "Hermes (Let's work agent)" OK "$HERMES" || row "Hermes (Let's work agent)" NO "Let's work opens Hermes agents" "scripts/setup.sh --only agent"
[[ -d app/build/GoldWareOS.app ]] && row "app built" OK "app/build/GoldWareOS.app" || row "app built" NO "" "make app"
[[ -d "/Applications/GoldWare OS.app" ]] && row "app installed" OK "/Applications/GoldWare OS.app" || row "app installed" NO "" "make install"
if [[ -d "/Applications/GoldWare OS.app" ]]; then
  STAMP="$(cat "/Applications/GoldWare OS.app/Contents/Resources/goldware-root.txt" 2>/dev/null)"
  if [[ -n "$STAMP" && -f "$STAMP/goldware.default.json" ]]; then row "app finds its checkout" OK "$STAMP"
  else row "app finds its checkout" NO "${STAMP:-no stamp} is gone" "the repo folder was moved or deleted; from the new folder run: make app && make install"; fi
fi
if curl -fsS --max-time 2 "http://127.0.0.1:$PORT/api/work" >/dev/null 2>&1; then row "server answering" OK "http://127.0.0.1:$PORT"
else row "server answering" NO "port $PORT" "make run-server   (or open the app, it starts the server)"; fi
if [[ -f server/goldware_server.py ]]; then
  OUT="$(python3 server/goldware_server.py --check 2>&1)" && row "goldware.json valid" OK "$(echo "$OUT" | tail -1)" || row "goldware.json valid" NO "$(echo "$OUT" | tail -1)" "fix the field named above, or restore goldware.json.bak"
else row "goldware.json valid" NO "server/goldware_server.py not found" "git pull"; fi

echo
(( BAD == 0 )) && echo "All good." || echo "$BAD item(s) missing. Run the fix commands above, or: make setup"
exit $(( BAD > 0 ))
