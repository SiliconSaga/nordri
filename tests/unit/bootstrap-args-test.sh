#!/usr/bin/env bash
# Shape test for Phase 3a's bootstrap and update scripts: the <realm> <cluster>
# contract, no patch libraries, no overlay sed, no envs copy, the identity
# written first, the policy override in both ArgoCD install places.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
fails=0
check() { if eval "$2"; then echo "ok - $1"; else echo "NOT OK - $1"; fails=$((fails+1)); fi; }
out=$(bash "$root/bootstrap.sh" 2>&1); rc=$?
check "bootstrap without args exits 1" "[[ $rc -eq 1 ]]"
check "bootstrap usage names realm and cluster" "[[ \"\$out\" == *'bootstrap.sh <realm> <cluster>'* ]]"
out=$(bash "$root/update-embedded-git.sh" 2>&1); rc=$?
check "update without args exits 1" "[[ $rc -eq 1 ]]"
check "update usage names the realm and --target" "[[ \"\$out\" == *'update-embedded-git.sh <realm> [--target forgejo]'* ]]"
for lib in patch-urls patch-velero patch-nidavellir patch-mimir; do
    check "lib/$lib.sh is gone" "[[ ! -e \"$root/lib/$lib.sh\" ]]"
done
check "envs/ is gone" "[[ ! -d \"$root/envs\" ]]"
for f in bootstrap.sh update-embedded-git.sh lib/hydrate.sh; do
    check "$f has no manifest sed" "! grep -q 'sed -i' \"$root/$f\""
    check "$f sources no patch lib" "! grep -q 'lib/patch-' \"$root/$f\""
done
check "bootstrap writes the identity first" "[[ \$(grep -n 'scripts/identity.sh apply' \"$root/bootstrap.sh\" | head -1 | cut -d: -f1) -lt \$(grep -n 'gitea_install_seed' \"$root/bootstrap.sh\" | head -1 | cut -d: -f1) ]]"
check "bootstrap enables the ApplicationSet policy override" "grep -q 'applicationsetcontroller\\\\.enable\\\\.policy\\\\.override' \"$root/bootstrap.sh\""
check "the argocd Application enables it too" "grep -q 'applicationsetcontroller.enable.policy.override: \"true\"' \"$root/platform/fundamentals/apps/argocd.yaml\""
check "no __GCP_PROJECT__ in platform/" "! grep -rq '__GCP_PROJECT__' \"$root/platform\""
check "hydration commits carry a Source-Commit trailer" "grep -q 'Source-Commit:' \"$root/lib/hydrate.sh\""
# Critical 3: a cluster the old code bootstrapped (root app not at the stable
# address) is refused before anything is written, and pointed at migrate.sh.
line_of() { grep -n -F -m1 -- "$1" "$root/bootstrap.sh" | cut -d: -f1; }
check "bootstrap reads nordri-root's repoURL" "grep -q 'nordri-root' \"$root/bootstrap.sh\" && grep -q 'spec.source.repoURL' \"$root/bootstrap.sh\""
check "the refusal compares against the stable address" "grep -q 'GIT_STABLE_BASE/' \"$root/bootstrap.sh\""
check "the refusal names scripts/migrate.sh" "grep -q 'refuse_old_code_cluster' \"$root/bootstrap.sh\" && sed -n '/^refuse_old_code_cluster()/,/^}/p' \"$root/bootstrap.sh\" | grep -q 'scripts/migrate.sh'"
check "the refusal runs before Layer -1 (the first identity write)" "[[ -n \"\$(line_of 'refuse_old_code_cluster || exit 1')\" && \$(line_of 'refuse_old_code_cluster || exit 1') -lt \$(line_of 'scripts/identity.sh\" apply') ]]"
check "README no longer sends an existing cluster to bootstrap.sh" "! grep -q 'GITEA_PASS=<live-password> ./bootstrap.sh' \"$root/README.md\""
check "docs/bootstrap.md no longer rotates through bootstrap.sh" "! grep -q 'GITEA_PASS=\"new-password\" ./bootstrap.sh' \"$root/docs/bootstrap.md\""
echo "---"; [ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
