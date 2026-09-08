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
check "seed snapshot has no forgejo-http in yaml" "! grep -rq 'forgejo-http' --include='*.yaml' '$tree'"
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

# a tree already in seed form (today's manifests) is a no-op in seed mode.
tree="$(mktemp -d)"; mkdir -p "$tree/platform/argocd"
printf "    repoURL: '%s/nordri.git'\n" "$seed" > "$tree/platform/argocd/app-of-apps.yaml"
out="$(patch_repo_urls_tree "$tree" seed)"; rc=$?
check "seed-form tree is a no-op" "[ $rc -eq 0 ] && [ \"$out\" = '0' ]"
rm -rf "$tree"

# unknown mode fails fast.
tree="$(make_tree)"
patch_repo_urls_tree "$tree" github >/dev/null 2>&1; rc=$?
check "unknown mode returns non-zero" "[ $rc -ne 0 ]"
check "unknown mode changed nothing" "grep -q 'forgejo-http' '$tree/platform/argocd/app-of-apps.yaml'"
rm -rf "$tree"

echo "---"; [ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
