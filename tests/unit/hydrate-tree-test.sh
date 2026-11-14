#!/usr/bin/env bash
# Unit test for hydrate_prepare_tree in lib/hydrate.sh: a git source is copied
# without its ignored files (no credential reaches the seed), a plain directory
# falls back to cp -r, and .git is never carried over.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
. "$root/lib/hydrate.sh"
fails=0
check() { if eval "$2"; then echo "ok - $1"; else echo "NOT OK - $1"; fails=$((fails+1)); fi; }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

src="$work/src"; dst="$work/dst"; mkdir -p "$src/secrets" "$dst"
git -C "$src" init -q
printf '*.key\nsecrets/\n' > "$src/.gitignore"
echo tracked > "$src/tracked.txt"
git -C "$src" add .gitignore tracked.txt
git -C "$src" -c user.email=t@t -c user.name=t commit -q -m init
echo new > "$src/untracked.txt"
echo k > "$src/x.key"
echo t > "$src/secrets/token"

hydrate_prepare_tree "$src" "$dst"
check "tracked file copied" "[[ -f \"\$dst/tracked.txt\" ]]"
check ".gitignore copied" "[[ -f \"\$dst/.gitignore\" ]]"
check "untracked unignored file copied" "[[ -f \"\$dst/untracked.txt\" ]]"
check "ignored *.key not copied" "[[ ! -e \"\$dst/x.key\" ]]"
check "ignored secrets/ not copied" "[[ ! -e \"\$dst/secrets\" ]]"
check ".git not copied" "[[ ! -e \"\$dst/.git\" ]]"

plain="$work/plain"; pdst="$work/pdst"; mkdir -p "$plain/sub" "$pdst"
echo a > "$plain/a.txt"; echo b > "$plain/sub/b.txt"; echo k > "$plain/x.key"
hydrate_prepare_tree "$plain" "$pdst"
check "non-git fallback copies files" "[[ -f \"\$pdst/a.txt\" && -f \"\$pdst/sub/b.txt\" && -f \"\$pdst/x.key\" ]]"
check "non-git fallback leaves no .git" "[[ ! -e \"\$pdst/.git\" ]]"
echo "---"; [ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
