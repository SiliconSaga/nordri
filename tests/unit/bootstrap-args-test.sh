#!/usr/bin/env bash
# shellcheck disable=SC2015
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
line_of() { grep -n -F -m1 -- "$1" "$root/bootstrap.sh" | cut -d: -f1; }
# The identity write (the quoted invocation, as bootstrap spells it) precedes the
# seed install call itself (not its earlier mention in a comment); both must be found.
id_w=$(line_of 'scripts/identity.sh" apply'); seed_w=$(grep -n -m1 '^gitea_install_seed' "$root/bootstrap.sh" | cut -d: -f1)
check "bootstrap writes the identity first" "[[ -n '$id_w' && -n '$seed_w' && '$id_w' -lt '$seed_w' ]]"
check "bootstrap enables the ApplicationSet policy override" "grep -q 'applicationsetcontroller\\\\.enable\\\\.policy\\\\.override' \"$root/bootstrap.sh\""
check "the argocd Application enables it too" "grep -q 'applicationsetcontroller.enable.policy.override: \"true\"' \"$root/platform/fundamentals/apps/argocd.yaml\""
check "no __GCP_PROJECT__ in platform/" "! grep -rq '__GCP_PROJECT__' \"$root/platform\""
check "hydration commits carry a Source-Commit trailer" "grep -q 'Source-Commit:' \"$root/lib/hydrate.sh\""
# Critical 3: a cluster the old code bootstrapped (root app not at the stable
# address) is refused before anything is written, and pointed at migrate.sh.
# The check lives in lib/gitops.sh (shared with reseed-gitea.sh); bootstrap calls it.
check "the refusal reads nordri-root's repoURL" "grep -q 'nordri-root' \"$root/lib/gitops.sh\" && grep -q 'spec.source.repoURL' \"$root/lib/gitops.sh\""
check "the refusal compares against the stable address" "sed -n '/^refuse_old_code_cluster()/,/^}/p' \"$root/lib/gitops.sh\" | grep -q 'GIT_STABLE_BASE/'"
check "the refusal names scripts/migrate.sh" "sed -n '/^refuse_old_code_cluster()/,/^}/p' \"$root/lib/gitops.sh\" | grep -q 'scripts/migrate.sh'"
# shellcheck disable=SC2016
refuse_call='refuse_old_code_cluster "$REALM" "$CLUSTER" || exit 1'
check "the refusal runs before Layer -1 (the first identity write)" "[[ -n \"\$(line_of '$refuse_call')\" && \$(line_of '$refuse_call') -lt \$(line_of 'scripts/identity.sh\" apply') ]]"
# reseed-gitea.sh: the same refusal, before the seed is reinstalled (a reseed wipes
# the repositories an old-code cluster's Applications still read).
rs_refuse=$(grep -n -F -m1 -- "$refuse_call" "$root/scripts/reseed-gitea.sh" | cut -d: -f1); rs_seed=$(grep -n -m1 '^gitea_install_seed' "$root/scripts/reseed-gitea.sh" | cut -d: -f1)
check "reseed refuses an old-code cluster before gitea_install_seed" "[[ -n '$rs_refuse' && -n '$rs_seed' && '$rs_refuse' -lt '$rs_seed' ]]"
check "README no longer sends an existing cluster to bootstrap.sh" "! grep -q 'GITEA_PASS=<live-password> ./bootstrap.sh' \"$root/README.md\""
check "docs/bootstrap.md no longer rotates through bootstrap.sh" "! grep -q 'GITEA_PASS=\"new-password\" ./bootstrap.sh' \"$root/docs/bootstrap.md\""
# Important 5: every script that derives the org refuses one the manifests do not read,
# before it first uses the org. The patterns are literal source text:
# shellcheck disable=SC2016
for f in bootstrap.sh update-embedded-git.sh scripts/migrate.sh; do
    g=$(grep -n -F -m1 'gitops_require_manifest_org "$REALM" || exit 1' "$root/$f" | cut -d: -f1)
    o=$(grep -n -F -m1 'GITOPS_ORG="$(gitops_canonical_org' "$root/$f" | cut -d: -f1)
    check "$f refuses a realm whose org the manifests do not read, before deriving it" "[[ -n '$g' && -n '$o' && '$g' -lt '$o' ]]"
done
# update-embedded-git.sh --target: a missing value and anything but forgejo are usage errors
out=$(bash "$root/update-embedded-git.sh" realm-x --target 2>&1); rc=$?
check "update --target with no value is a usage error" "[[ $rc -eq 1 && \"\$out\" == *'--target needs a value'* ]]"
out=$(bash "$root/update-embedded-git.sh" realm-x --target seed 2>&1); rc=$?
check "update --target seed is refused" "[[ $rc -eq 1 && \"\$out\" == *'--target must be forgejo'* ]]"
out=$(bash "$root/scripts/reseed-gitea.sh" 'Realm_X' homelab-prod 2>&1); rc=$?
check "reseed refuses a realm that is not a DNS-1123 label" "[[ $rc -eq 1 && \"\$out\" == *'DNS-1123'* ]]"
out=$(bash "$root/scripts/reseed-gitea.sh" realm-x 'Bad_Cluster' 2>&1); rc=$?
check "reseed refuses a cluster that is not a DNS-1123 label" "[[ $rc -eq 1 && \"\$out\" == *'DNS-1123'* ]]"
check "docs match the code: --target forgejo is refused on any prod cluster" "! grep -q 'refused on a graduated .prod. cluster' \"$root/CLAUDE.md\" \"$root/docs/bootstrap.md\" && ! grep -q 'Refused$' \"$root/update-embedded-git.sh\""
# Behaviour of refuse_old_code_cluster, extracted and run against a kubectl stub.
# K_CRD_ERR: error text for the CRD get (empty = installed); K_APP_FAIL=1: the
# application get fails; K_ROW: what the application get prints.
fn="$(sed -n '/^refuse_old_code_cluster()/,/^}/p' "$root/lib/gitops.sh")"
refuse() (
    # shellcheck disable=SC2329
    kubectl() {
        case "$*" in
            'get crd'*) [[ -z "${K_CRD_ERR:-}" ]] && return 0; echo "$K_CRD_ERR" >&2; return 1 ;;
            'get application'*) [[ -n "${K_APP_FAIL:-}" ]] && return 1; printf '%s' "${K_ROW:-}" ;;
        esac
    }
    GIT_STABLE_BASE="http://stable.example"
    eval "$fn"
    refuse_old_code_cluster realm-x c1
)
K_CRD_ERR='Error from server (NotFound): customresourcedefinitions "applications.argoproj.io" not found' refuse >/dev/null 2>&1; rc=$?
check "refuse_old_code_cluster: no Application CRD (fresh cluster) passes" "[[ $rc -eq 0 ]]"
K_CRD_ERR='Unable to connect to the server' refuse >/dev/null 2>&1; rc=$?
check "refuse_old_code_cluster: any other CRD error is refused" "[[ $rc -eq 1 ]]"
K_APP_FAIL=1 refuse >/dev/null 2>&1; rc=$?
check "refuse_old_code_cluster: an unreadable nordri-root is refused" "[[ $rc -eq 1 ]]"
K_ROW='' refuse >/dev/null 2>&1; rc=$?
check "refuse_old_code_cluster: no nordri-root passes" "[[ $rc -eq 0 ]]"
K_ROW='nordri-root|http://stable.example/realm-x/nordri.git' refuse >/dev/null 2>&1; rc=$?
check "refuse_old_code_cluster: a root at the stable base passes" "[[ $rc -eq 0 ]]"
K_ROW='nordri-root|http://gitea-http.gitea:3000/nordri-admin/nordri.git' refuse >/dev/null 2>&1; rc=$?
check "refuse_old_code_cluster: a root elsewhere is refused" "[[ $rc -eq 1 ]]"
out="$(K_ROW='nordri-root|http://gitea-http.gitea:3000/nordri-admin/nordri.git' refuse 2>&1)"
check "refuse_old_code_cluster: the refusal names scripts/migrate.sh with realm and cluster" "[[ \"\$out\" == *'scripts/migrate.sh realm-x c1'* ]]"
echo "---"; [ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
