#!/usr/bin/env bash
# Every identity lookup in an ApplicationSet template is guarded (index on a
# missing key yields "", which would render a path like overlays/), and every
# ApplicationSet carries the two settings that keep an empty generator from
# deleting anything. Realm Phase 3 design, Decision 4.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
fails=0
check() { if eval "$2"; then echo "ok - $1"; else echo "NOT OK - $1"; fails=$((fails+1)); fi; }
files=$(grep -rl '^kind: ApplicationSet' "$root/platform")
check "there are ApplicationSets" "[[ -n \"\$files\" ]]"
for f in $files; do
    rel="${f#"$root"/}"
    check "$rel: goTemplate" "grep -q 'goTemplate: true' \"$f\""
    check "$rel: missingkey=error" "grep -q 'missingkey=error' \"$f\""
    check "$rel: preserveResourcesOnDeletion" "grep -q 'preserveResourcesOnDeletion: true' \"$f\""
    check "$rel: applicationsSync create-update" "grep -q 'applicationsSync: create-update' \"$f\""
    while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        check "$rel: $key is guarded" "grep -q \"if not (index .metadata.[a-z]* \$key)\" \"$f\""
    done < <(grep -o 'index .metadata.[a-z]* "nordri.siliconsaga.org/[a-z-]*"' "$f" | grep -o '"nordri[^"]*"' | sort -u)
done
check "no identity manifest left in platform/" "! ls \"$root\"/platform/fundamentals/manifests/cluster-identity-*.yaml 2>/dev/null | grep -q ."
echo "---"; [ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
