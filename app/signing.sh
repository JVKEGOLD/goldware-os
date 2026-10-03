#!/bin/zsh
# Prints the code-signing identity build.sh should use, creating a stable one on first run.
#
# Why: macOS remembers Microphone, Accessibility, Camera and Speech Recognition grants by the
# app's code signature. An ad-hoc signature changes on every rebuild, so after each update macOS
# treats GoldWare OS as a new app and the grants silently stop working (the switch still shows
# "on" in System Settings). Signing every build with the same certificate keeps the grants.
#
# Order:
#   1. GOLDWARE_SIGN_IDENTITY, if set (any identity name or SHA-1 from `security find-identity`)
#   2. an "Apple Development" certificate, if this Mac has one
#   3. a self-signed "GoldWare OS Local Signing" certificate, made once per Mac and kept in its own
#      keychain under ~/Library/Application Support/GoldWare OS/signing (never in the repo, never
#      shared, never in the login keychain, no admin password, no trust settings changed)
#   4. "-" (ad-hoc) only if all of the above fail
#
# Output (stdout, one line): <identity>\t<keychain path or empty>
# Messages go to stderr.
set -uo pipefail

NAME="GoldWare OS Local Signing"
DIR="${GOLDWARE_SIGNING_DIR:-$HOME/Library/Application Support/GoldWare OS/signing}"
KC="$DIR/goldware-signing.keychain-db"
PWF="$DIR/keychain-password"

say() { print -r -- "$*" >&2; }

if [[ -n "${GOLDWARE_SIGN_IDENTITY:-}" ]]; then
  print -r -- "$GOLDWARE_SIGN_IDENTITY"$'\t'; exit 0
fi

dev=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')
if [[ -n "$dev" ]]; then print -r -- "$dev"$'\t'; exit 0; fi

# SHA-1 of our identity in our keychain (find-identity without -v: self-signed is not "valid"
# for policy purposes, but codesign accepts it).
local_identity() {
  security find-identity -p codesigning "$KC" 2>/dev/null \
    | awk -v n="\"$NAME\"" 'index($0, n) {print $2; exit}'
}

unlock() {
  [[ -f "$KC" && -f "$PWF" ]] || return 1
  security unlock-keychain -p "$(<"$PWF")" "$KC" 2>/dev/null
}

create() {
  say "Creating a signing certificate for this Mac (once): $NAME"
  mkdir -p "$DIR" && chmod 700 "$DIR" || return 1
  rm -f "$KC" "$PWF"
  local tmp; tmp=$(mktemp -d) || return 1
  { umask 077; openssl rand -hex 24 > "$PWF"; } || { rm -rf "$tmp"; return 1; }
  local kpw p12pw; kpw="$(<"$PWF")"; p12pw="$(openssl rand -hex 16)"
  cat > "$tmp/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
O = GoldWare OS (this Mac only)
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
  # 20 years: the certificate must outlive the app, or grants reset when it is replaced.
  openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -sha256 -config "$tmp/cert.cnf" \
      -keyout "$tmp/key.pem" -out "$tmp/cert.pem" >/dev/null 2>&1 \
    && openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$NAME" \
      -passout "pass:$p12pw" -out "$tmp/id.p12" >/dev/null 2>&1 \
    && security create-keychain -p "$kpw" "$KC" >/dev/null \
    && security set-keychain-settings "$KC" \
    && security unlock-keychain -p "$kpw" "$KC" \
    && security import "$tmp/id.p12" -k "$KC" -P "$p12pw" -T /usr/bin/codesign >/dev/null \
    && security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$kpw" "$KC" >/dev/null 2>&1
  local rc=$?
  rm -rf "$tmp"
  (( rc == 0 )) || { say "Could not create the signing certificate (rc $rc)."; rm -f "$KC" "$PWF"; return 1; }
}

# codesign only finds identities in keychains on the user search list; add ours once, keeping the rest.
on_search_list() {
  local kc; kc=$(cd "$DIR" && pwd -P)/${KC:t}
  security list-keychains -d user | tr -d '"' | sed 's/^ *//' | grep -qxF "$kc" && return 0
  local -a list; list=("${(@f)$(security list-keychains -d user | tr -d '"' | sed 's/^ *//')}")
  security list-keychains -d user -s "${list[@]}" "$kc"
}

id=""
if unlock; then id=$(local_identity); fi
if [[ -z "$id" ]] && create; then id=$(local_identity); fi
if [[ -n "$id" ]] && on_search_list; then
  print -r -- "$id"$'\t'"$KC"; exit 0
fi

say "Falling back to ad-hoc signing; macOS may forget permissions after each rebuild."
print -r -- "-"$'\t'
