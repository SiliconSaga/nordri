#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/patch-urls.sh"

fails=0
check() { if eval "$2"; then echo "ok - $1"; else echo "NOT OK - $1"; fails=$((fails+1)); fi; }

forgejo='http://forgejo-http.forgejo.svc.cluster.local:3000/siliconsaga'
seed='http://gitea-http.gitea.svc.cluster.local:3000/nordri-admin'

make_tree() { # a fake hydrated tree carrying the COMMITTED (Forgejo) form
    local t; t="$(mktemp -d)"
    mkdir -p "$t/platform/argocd" "$t/apps"
    printf "    repoURL: '%s/nordri.git'\n" "$forgejo" > "$t/platform/argocd/app-of-apps.yaml"
    printf "    repoURL: '%s/nidavellir.git'\n" "$forgejo" > "$t/apps/mimir-app.yaml"
    printf "not a manifest: %s/should-not-change.git\n" "$forgejo" > "$t/README.md"
    printf '%s' "$t"
}

# seed: every yaml rewritten to the seed form, non-yaml untouched.
tree="$(make_tree)"
out="$(patch_repo_urls_tree "$tree" seed)"; rc=$?
check "seed returns 0" "[ $rc -eq 0 ]"
check "seed snapshot has no forgejo-http in yaml" "! grep -q 'forgejo-http' '$tree/platform/argocd/app-of-apps.yaml' '$tree/apps/mimir-app.yaml'"
check "seed snapshot carries the seed URL" "grep -q \"$seed/nordri.git\" '$tree/platform/argocd/app-of-apps.yaml'"
check "seed rewrites nested apps too" "grep -q \"$seed/nidavellir.git\" '$tree/apps/mimir-app.yaml'"
check "seed leaves non-yaml alone" "grep -q 'forgejo-http' '$tree/README.md'"
check "seed reports two files" "[ \"$out\" = '2' ]"
rm -rf "$tree"

# forgejo: nothing changes.
tree="$(make_tree)"
patch_repo_urls_tree "$tree" forgejo >/dev/null; rc=$?
check "forgejo returns 0" "[ $rc -eq 0 ]"
check "forgejo snapshot has no gitea-http" "! grep -rq 'gitea-http' '$tree'"
check "forgejo snapshot keeps forgejo-http" "grep -q 'forgejo-http' '$tree/platform/argocd/app-of-apps.yaml'"
rm -rf "$tree"

# swap: same as forgejo — the URLs are the whole point of the swap commit.
tree="$(make_tree)"
patch_repo_urls_tree "$tree" swap >/dev/null; rc=$?
check "swap returns 0" "[ $rc -eq 0 ]"
check "swap snapshot has no gitea-http" "! grep -rq 'gitea-http' '$tree'"
rm -rf "$tree"

# forgejo/swap must REFUSE a tree that still carries a seed URL — that is the
# one manifest that would point ArgoCD back at the retired seed.
tree="$(make_tree)"
printf "    repoURL: '%s/heimdall.git'\n" "$seed" > "$tree/apps/heimdall-app.yaml"
patch_repo_urls_tree "$tree" swap >/dev/null 2>&1; rc=$?
check "swap refuses a leftover seed URL" "[ $rc -ne 0 ]"
patch_repo_urls_tree "$tree" forgejo >/dev/null 2>&1; rc=$?
check "forgejo refuses a leftover seed URL" "[ $rc -ne 0 ]"
check "refusal changed nothing" "grep -q \"$seed/heimdall.git\" '$tree/apps/heimdall-app.yaml'"
rm -rf "$tree"

# single-file entry point, used for the out-of-tree root-app manifests.
f="$(mktemp)"
printf "    repoURL: '%s/nordri.git'\n" "$forgejo" > "$f"
out="$(patch_repo_urls_file "$f" seed)"; rc=$?
check "file: seed rewrites and reports 1" "[ $rc -eq 0 ] && [ \"$out\" = '1' ] && grep -q \"$seed/nordri.git\" '$f'"
out="$(patch_repo_urls_file "$f" seed)"; rc=$?
check "file: already-seed is a no-op reporting 0" "[ $rc -eq 0 ] && [ \"$out\" = '0' ]"
patch_repo_urls_file "$f" swap >/dev/null 2>&1; rc=$?
check "file: swap refuses the seed form" "[ $rc -ne 0 ]"
rm -f "$f"

# a tree already in seed form (today's manifests) is a no-op in seed mode.
tree="$(mktemp -d)"; mkdir -p "$tree/platform/argocd"
printf "    repoURL: '%s/nordri.git'\n" "$seed" > "$tree/platform/argocd/app-of-apps.yaml"
out="$(patch_repo_urls_tree "$tree" seed)"; rc=$?
check "seed-form tree is a no-op" "[ $rc -eq 0 ] && [ \"$out\" = '0' ]"
rm -rf "$tree"

# edge cases the loop must survive: no yaml at all, the URL twice on one line,
# and a path with spaces (find -print0 / read -d '' is what makes that safe).
tree="$(mktemp -d)"; mkdir -p "$tree/docs"
printf '%s/x.git\n' "$forgejo" > "$tree/docs/notes.md"
out="$(patch_repo_urls_tree "$tree" seed)"; rc=$?
check "no-yaml tree returns 0 and reports 0" "[ $rc -eq 0 ] && [ \"$out\" = '0' ]"
rm -rf "$tree"

tree="$(mktemp -d)"; mkdir -p "$tree/with space/apps"
printf "a: '%s/a.git' b: '%s/b.git'\n" "$forgejo" "$forgejo" > "$tree/with space/apps/twice.yaml"
out="$(patch_repo_urls_tree "$tree" seed)"; rc=$?
check "spaced path handled and both URLs on one line rewritten" "[ $rc -eq 0 ] && [ \"$out\" = '1' ] && ! grep -q 'forgejo-http' \"$tree/with space/apps/twice.yaml\""
check "spaced path carries both seed URLs" "[ \"\$(grep -o 'gitea-http' \"$tree/with space/apps/twice.yaml\" | wc -l | tr -d ' ')\" = '2' ]"
rm -rf "$tree"

# literal matching: a near-miss host (one dot replaced by another character)
# must be left alone in seed mode and must not count as a seed URL otherwise.
tree="$(mktemp -d)"; mkdir -p "$tree/apps"
near="${forgejo/forgejo-http.forgejo/forgejo-httpXforgejo}"
printf "    repoURL: '%s/nordri.git'\n" "$near" > "$tree/apps/near.yaml"
out="$(patch_repo_urls_tree "$tree" seed)"; rc=$?
check "near-miss host untouched in seed mode" "[ $rc -eq 0 ] && [ \"$out\" = '0' ] && grep -Fq -- \"$near\" '$tree/apps/near.yaml'"
patch_repo_urls_tree "$tree" swap >/dev/null; rc=$?
check "near-miss host is not a seed URL in swap mode" "[ $rc -eq 0 ]"
rm -rf "$tree"

# an unreadable file must fail the scan rather than pass as clean.
f="$(mktemp)"; rm -f "$f"
patch_repo_urls_file "$f" swap >/dev/null 2>&1; rc=$?
check "file: unreadable input is an error in swap mode" "[ $rc -ne 0 ]"

# unknown mode fails fast.
tree="$(make_tree)"
patch_repo_urls_tree "$tree" github >/dev/null 2>&1; rc=$?
check "unknown mode returns non-zero" "[ $rc -ne 0 ]"
check "unknown mode changed nothing" "grep -q 'forgejo-http' '$tree/platform/argocd/app-of-apps.yaml'"
rm -rf "$tree"

echo "---"; [ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
