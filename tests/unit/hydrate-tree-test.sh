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
# Nested checkout: its .git and ignored files must not ride along.
nsrc="$work/nsrc"; ndst="$work/ndst"; mkdir -p "$nsrc/sub" "$ndst"
git -C "$nsrc" init -q
echo top > "$nsrc/top.txt"
git -C "$nsrc" add top.txt
git -C "$nsrc" -c user.email=t@t -c user.name=t commit -q -m init
git -C "$nsrc/sub" init -q
printf '.env\n' > "$nsrc/sub/.gitignore"
echo inner > "$nsrc/sub/inner.txt"
git -C "$nsrc/sub" add .gitignore inner.txt
git -C "$nsrc/sub" -c user.email=t@t -c user.name=t commit -q -m init
echo secret > "$nsrc/sub/.env"
hydrate_prepare_tree "$nsrc" "$ndst"
check "nested repo: top file copied" "[[ -f \"\$ndst/top.txt\" ]]"
check "nested repo: sub/.git not copied" "[[ ! -e \"\$ndst/sub/.git\" ]]"
check "nested repo: sub/.env not copied" "[[ ! -e \"\$ndst/sub/.env\" ]]"

# Failing creator: a tracked file deleted from the work tree must fail the copy.
fsrc="$work/fsrc"; fdst="$work/fdst"; mkdir -p "$fsrc" "$fdst"
git -C "$fsrc" init -q
echo gone > "$fsrc/gone.txt"
git -C "$fsrc" add gone.txt
git -C "$fsrc" -c user.email=t@t -c user.name=t commit -q -m init
rm "$fsrc/gone.txt"
# Callers run set -e without pipefail, so mirror that here or a pipeline hides it.
check "creator failure returns non-zero" "( set +o pipefail; ! hydrate_prepare_tree \"\$fsrc\" \"\$fdst\" 2>/dev/null )"

# Path with a space survives the NUL-separated list.
ssrc="$work/ssrc"; sdst="$work/sdst"; mkdir -p "$ssrc/dir with space" "$sdst"
git -C "$ssrc" init -q
echo s > "$ssrc/dir with space/file one.txt"
git -C "$ssrc" add .
git -C "$ssrc" -c user.email=t@t -c user.name=t commit -q -m init
hydrate_prepare_tree "$ssrc" "$sdst"
check "path with a space copied" "[[ -f \"\$sdst/dir with space/file one.txt\" ]]"

echo "---"; [ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
