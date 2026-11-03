#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/patch-mimir.sh"

fails=0
check() { if eval "$2"; then echo "ok - $1"; else echo "NOT OK - $1"; fails=$((fails+1)); fi; }

# Arrange: a fake hydrated mimir tree — the Application carrying the generic
# path, plus both realm overlays the patch is allowed to point at.
tree="$(mktemp -d)"; trap 'rm -rf "$tree"' EXIT
seed_tree() {
    mkdir -p "$tree/argocd/apps" "$tree/shared/overlays/gke" "$tree/shared/overlays/homelab"
    printf 'spec:\n  source:\n    path: shared\n' > "$tree/argocd/apps/shared-clusters.yaml"
    : > "$tree/shared/overlays/gke/kustomization.yaml"
    : > "$tree/shared/overlays/homelab/kustomization.yaml"
}
seed_tree

# Act + assert: each target points the app at its own overlay.
patch_mimir_tree "$tree" homelab; rc=$?
check "homelab returns 0" "[ $rc -eq 0 ]"
check "homelab overlay selected" "grep -q 'path: shared/overlays/homelab' '$tree/argocd/apps/shared-clusters.yaml'"
check "generic path is gone" "! grep -qx '    path: shared' '$tree/argocd/apps/shared-clusters.yaml'"
check "indentation preserved" "grep -q '^    path: shared/overlays/homelab$' '$tree/argocd/apps/shared-clusters.yaml'"

seed_tree
patch_mimir_tree "$tree" gke >/dev/null
check "gke overlay selected" "grep -q 'path: shared/overlays/gke' '$tree/argocd/apps/shared-clusters.yaml'"
check "gke did not get homelab's overlay" "! grep -q 'overlays/homelab' '$tree/argocd/apps/shared-clusters.yaml'"

# ⚠ THE ONE THAT MATTERS. `sed` exits 0 when nothing matched, so a renamed
# placeholder would leave the app on the flat `shared/` path. On GKE that
# silently drops repo2 and every MySQL backup while every app stays green —
# which is why the verification is a hard error and why it is tested here.
seed_tree
printf 'spec:\n  source:\n    path: RENAMED\n' > "$tree/argocd/apps/shared-clusters.yaml"
patch_mimir_tree "$tree" gke >/dev/null 2>&1; rc=$?
check "renamed path placeholder returns non-zero" "[ $rc -ne 0 ]"

# A path that merely STARTS WITH the overlay must not satisfy the check. The sed
# leaves `overlays/gke-old` alone (it only matches a bare `path: shared`), so a
# substring grep would return 0 on a manifest it never touched.
seed_tree
printf 'spec:\n  source:\n    path: shared/overlays/gke-old\n' > "$tree/argocd/apps/shared-clusters.yaml"
patch_mimir_tree "$tree" gke >/dev/null 2>&1; rc=$?
check "overlay-prefixed path returns non-zero" "[ $rc -ne 0 ]"
check "overlay-prefixed path left unchanged" "grep -q 'path: shared/overlays/gke-old' '$tree/argocd/apps/shared-clusters.yaml'"

# A 'path:' in prose must not be mistaken for the field (the sed is anchored).
seed_tree
printf 'spec:\n  source:\n    path: shared\n# note: path: shared used to be flat\n' \
    > "$tree/argocd/apps/shared-clusters.yaml"
patch_mimir_tree "$tree" homelab >/dev/null; rc=$?
check "trailing comment left intact" "grep -q '# note: path: shared used to be flat' '$tree/argocd/apps/shared-clusters.yaml'"

# Missing Application must fail loudly rather than with a bare sed error.
seed_tree
rm -f "$tree/argocd/apps/shared-clusters.yaml"
patch_mimir_tree "$tree" homelab >/dev/null 2>&1; rc=$?
check "missing manifest returns non-zero" "[ $rc -ne 0 ]"

# A target whose overlay was never written must fail BEFORE pointing the app at
# a dangling path — the app's syncPolicy has prune disabled, so the old
# resources keep running and the breakage would otherwise be quiet.
seed_tree
rm -rf "$tree/shared/overlays/gke"
patch_mimir_tree "$tree" gke >/dev/null 2>&1; rc=$?
check "missing overlay returns non-zero" "[ $rc -ne 0 ]"
check "app left on the generic path when refused" "grep -q 'path: shared$' '$tree/argocd/apps/shared-clusters.yaml'"

# Empty/unknown target must fail fast rather than compose overlays/<bad>.
seed_tree
patch_mimir_tree "$tree" "" >/dev/null 2>&1; rc=$?
check "empty target returns non-zero" "[ $rc -ne 0 ]"
patch_mimir_tree "$tree" staging >/dev/null 2>&1; rc=$?
check "unknown target returns non-zero" "[ $rc -ne 0 ]"
check "refused target changed nothing" "grep -q 'path: shared$' '$tree/argocd/apps/shared-clusters.yaml'"

echo "---"; [ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
