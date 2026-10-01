#!/bin/zsh
# Fails if anything personal from the author's own setup is in the tree.
# Terms live in ~/.config/goldware-os/private-terms.txt (one regex per line, outside the repo),
# so the list itself never ships. Without that file only the generic patterns run.
set -uo pipefail
cd "$(dirname "$0")/.."

terms_file="${GOLDWARE_PRIVATE_TERMS:-$HOME/.config/goldware-os/private-terms.txt}"
patterns=(
  '/Users/[a-z]+/'          # absolute home paths
  'sk-[A-Za-z0-9]{20,}'     # API keys
  'ghp_[A-Za-z0-9]{20,}'
  'pit-[0-9a-f-]{20,}'
)
if [[ -f "$terms_file" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    patterns+=("$line")
  done < "$terms_file"
fi

files=("${(@f)$(git ls-files --cached --others --exclude-standard | grep -v '^scripts/check_private.sh$')}")
fail=0
for p in "${patterns[@]}"; do
  hits=$(grep -nIiE -- "$p" "${files[@]}" 2>/dev/null | head -20)
  if [[ -n "$hits" ]]; then
    echo "PRIVATE TERM: $p"
    echo "$hits" | sed 's/^/  /'
    fail=1
  fi
done
if (( fail )); then echo "check_private: FAILED"; exit 1; fi
echo "check_private: clean (${#patterns[@]} patterns, ${#files[@]} files)"
