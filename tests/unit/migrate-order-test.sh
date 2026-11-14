#!/usr/bin/env bash
# Unit test for scripts/migrate.sh: the order of the eight 3a-5 steps and its
# refusals. migrate.sh runs from a scratch copy of the component whose libs and
# identity.sh are recording stubs; kubectl is a stub too. Every stub writes to the
# same stream (stdout, or stderr for kubectl), so line numbers give the order.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
fails=0
check() { if eval "$2"; then echo "ok - $1"; else echo "NOT OK - $1"; fails=$((fails+1)); fi; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/nordri/scripts" "$work/nordri/lib" "$work/bin" "$work/realm"
cp "$root/scripts/migrate.sh" "$work/nordri/scripts/migrate.sh" 2>/dev/null

stub() { printf '%s\n' "$2" > "$work/nordri/$1"; }
stub lib/gitea.sh ':'
stub lib/kube-context.sh 'require_kube_context() { echo "CALL require_kube_context $*"; }'
stub lib/identity.sh 'identity_live_value() { printf "%s" "${STUB_LIVE_CLUSTER:-}"; }
identity_resolve() { printf "environment=homelab\ncluster=%s\n" "$2"; }'
stub lib/hydrate.sh 'hydrate_working_tree_repo() { echo "CALL hydrate_working_tree_repo $2 $3"; }
hydrate_vendor_mirrors() { echo "CALL hydrate_vendor_mirrors $1"; }'
stub lib/gitops.sh 'gitops_canonical_org() { printf "%s" "${1#realm-}"; }
gitops_vendor_org() { printf "%s-vendor" "${1#realm-}"; }
gitops_ensure_org() { echo "CALL gitops_ensure_org $1"; }
gitops_ensure_git_service() { echo "CALL gitops_ensure_git_service"; }
gitops_apply_root_apps() { echo "CALL gitops_apply_root_apps $1"; }'
stub lib/seed-access.sh 'seed_access_open() { echo "CALL seed_access_open"; }'
stub lib/argo.sh 'argo_wait_operations_done() { echo "CALL argo_wait_operations_done $1"; }
argo_wait_synced_healthy() { echo "CALL argo_wait_synced_healthy $1"; }
argo_hard_refresh_all() { echo "CALL argo_hard_refresh_all"; }
argo_remove_finalizer() { echo "CALL argo_remove_finalizer $1"; }'
stub scripts/identity.sh 'echo "CALL identity.sh $*"'

cat > "$work/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
echo "KUBECTL $*" >> "$STUB_KUBE_LOG"
case "$*" in
  *argocd-cmd-params-cm*) printf '%s' "${STUB_OVERRIDE:-true}" ;;
esac
exit 0
STUB
chmod +x "$work/bin/kubectl"
export PATH="$work/bin:$PATH"

run() { : > "$work/kube.log"; export STUB_KUBE_LOG="$work/kube.log"; REALM_DIR="$work/realm" MIGRATE_DRY_RUN=1 bash "$work/nordri/scripts/migrate.sh" "$@" > "$work/out" 2>&1; }
# line number of the first / last line matching a fixed string
first() { grep -n -F -m1 -- "$1" "$work/out" | cut -d: -f1; }
last() { grep -n -F -- "$1" "$work/out" | tail -n 1 | cut -d: -f1; }

STUB_OVERRIDE=true run realm-x homelab-prod; rc=$?
check "the happy path exits 0" "[[ $rc -eq 0 ]]"
check "the policy override is read from argocd-cmd-params-cm" "grep -q 'KUBECTL get configmap -n argo argocd-cmd-params-cm' \"\$work/kube.log\""
check "the kube context is checked, never switched" "grep -q 'CALL require_kube_context homelab' \"\$work/out\" && ! grep -q 'use-context' \"\$work/out\""

i1=$(first "CALL identity.sh apply realm-x homelab-prod"); i2=$(last "CALL identity.sh apply realm-x homelab-prod")
f1=$(first "CALL argo_remove_finalizer tailscale-operator"); f2=$(first "CALL argo_remove_finalizer vegvisir"); f3=$(first "CALL argo_remove_finalizer velero")
o1=$(first "CALL gitops_ensure_org x"); o2=$(first "CALL gitops_ensure_org x-vendor"); svc=$(first "CALL gitops_ensure_git_service")
seed=$(first "CALL seed_access_open"); hyd=$(first "(dry run) hydrate skipped")
roots=$(first "CALL gitops_apply_root_apps realm-x"); ref=$(first "CALL argo_hard_refresh_all")
ops=$(first "CALL argo_wait_operations_done"); sh=$(first "CALL argo_wait_synced_healthy"); lastcall=$(grep -n -F "CALL " "$work/out" | tail -n 1 | cut -d: -f2)

check "identity apply runs twice" "[[ -n '$i1' && -n '$i2' && '$i1' != '$i2' ]]"
check "identity apply comes before the finalizer patches" "[[ '$i1' -lt '$f1' ]]"
check "the three finalizers go in order tailscale-operator, vegvisir, velero" "[[ -n '$f1' && '$f1' -lt '$f2' && '$f2' -lt '$f3' ]]"
check "the seed is opened after the finalizers" "[[ '$f3' -lt '$seed' ]]"
check "both orgs and the git Service come after the seed is open" "[[ '$seed' -lt '$o1' && '$o1' -lt '$o2' && '$o2' -lt '$svc' ]]"
check "the orgs and Service come before the hydrate" "[[ '$svc' -lt '$hyd' ]]"
check "root apps are applied after the hydrate and before the hard refresh" "[[ '$hyd' -lt '$roots' && '$roots' -lt '$ref' ]]"
check "operations are awaited after the hard refresh" "[[ '$ref' -lt '$ops' ]]"
check "the second identity apply follows argo_wait_operations_done" "[[ '$ops' -lt '$i2' ]]"
check "argo_wait_synced_healthy is after the second identity apply" "[[ '$i2' -lt '$sh' ]]"
check "argo_wait_synced_healthy is the last call" "[[ '$lastcall' == *argo_wait_synced_healthy* ]]"
check "the dry run pushes nothing" "! grep -q 'CALL hydrate_' \"\$work/out\""

# Refusal: policy override off
STUB_OVERRIDE=false run realm-x homelab-prod; rc=$?
check "an off policy override is refused" "[[ $rc -eq 1 ]]"
check "the refusal names argocd-cmd-params-cm" "grep -q 'argocd-cmd-params-cm' \"\$work/out\""
check "nothing else runs after the refusal" "! grep -q 'CALL identity.sh' \"\$work/out\""

# Refusal: the live identity names another cluster
STUB_OVERRIDE=true STUB_LIVE_CLUSTER=homelab-test run realm-x homelab-prod; rc=$?
check "a live identity naming another cluster is refused" "[[ $rc -eq 1 ]]"
check "the refusal names both clusters" "grep -q 'homelab-test' \"\$work/out\" && grep -q 'homelab-prod' \"\$work/out\""
check "nothing runs after the mismatch" "! grep -q 'CALL identity.sh' \"\$work/out\" && ! grep -q 'CALL argo' \"\$work/out\""

# Usage
run realm-x; rc=$?
check "a missing cluster is a usage error" "[[ $rc -eq 1 ]] && grep -q Usage \"\$work/out\""

echo "---"; [ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
