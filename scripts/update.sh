#!/bin/zsh
# Updates GoldWare OS without losing your changes. Changes nothing if they cannot be combined.
#   scripts/update.sh [setup options, e.g. --yes]
# Your settings (goldware.json) and data (data/) are never tracked by git, so an update never
# touches them. Changes you or your AI made to the code (dashboard, app, server) are saved as
# your own commit first, then the update is merged in on top, then setup rebuilds.
set -uo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT" || exit 1

ok()   { print -P "  %F{green}OK%f   $1"; }
fail() { print -P "  %F{red}FAIL%f $1" >&2; shift; for l in "$@"; do print "       $l" >&2; done; exit 1; }

[[ -d .git ]] || fail "This folder is not a git checkout." "Download it again with git clone (see README)."
[[ -e .git/MERGE_HEAD || -d .git/rebase-merge || -d .git/rebase-apply ]] \
  && fail "A previous update is half finished." "Ask your AI to finish or undo it (git merge --abort), then rerun: make update"

# git refuses to commit without a name; use a neutral local one only if none is set.
ident=()
git config user.name >/dev/null 2>&1 || ident+=(-c "user.name=GoldWare user")
git config user.email >/dev/null 2>&1 || ident+=(-c "user.email=user@localhost")

print -P "\n%B==> Saving your changes%b"
if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
  git add -A && git "${ident[@]}" commit -q -m "My changes (saved by make update, $(date '+%Y-%m-%d %H:%M'))" \
    || fail "Could not save your changes." "Nothing was updated."
  ok "saved as a commit on this Mac: $(git log -1 --format=%h)"
else
  ok "nothing to save"
fi

print -P "\n%B==> Downloading the update%b"
before="$(git rev-parse HEAD)"
git fetch -q origin || fail "Could not reach GitHub." "Check the internet connection, then rerun: make update"
branch="$(git rev-parse --abbrev-ref HEAD)"
if ! git "${ident[@]}" merge -q --no-edit "origin/$branch"; then
  git merge --abort >/dev/null 2>&1
  git reset -q --hard "$before"
  fail "The update and your changes edit the same lines, so nothing was changed." \
       "Your version is exactly as it was. Ask your AI: \"run git merge origin/$branch in goldware-os and keep my changes\"," \
       "or keep using this version."
fi
[[ "$(git rev-parse HEAD)" == "$before" ]] && ok "already up to date" || ok "updated, your changes kept"

print -P "\n%B==> Rebuilding%b"
exec scripts/setup.sh "$@"
