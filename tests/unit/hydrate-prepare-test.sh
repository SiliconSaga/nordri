#!/usr/bin/env bash
set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/../../lib/hydrate.sh"

fails=0
check() { if eval "$2"; then echo "ok - $1"; else echo "NOT OK - $1"; fails=$((fails+1)); fi; }

src="$(mktemp -d)"; dst="$(mktemp -d)"; trap 'rm -rf "$src" "$dst"' EXIT
mkdir -p "$src/.git" "$src/apps"
echo x > "$src/apps/a.yaml"
echo secret > "$src/.git/config"

hydrate_prepare_tree "$src" "$dst"
check "content copied" "[ -f '$dst/apps/a.yaml' ]"
check ".git stripped" "[ ! -e '$dst/.git' ]"

echo "---"; [ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
