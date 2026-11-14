#!/usr/bin/env bash
# shellcheck disable=SC2015
# Unit test for scripts/identity.sh apply: the ConfigMap, the in-cluster
# Secret's labels and annotations, the EnvironmentConfig handover, and the
# cluster-name guard. kubectl is a recording stub.
#
# The handover contract (design, Decision 4 step 2): an EnvironmentConfig that
# ArgoCD tracks, by label (app.kubernetes.io/instance) or by annotation
# (argocd.argoproj.io/tracking-id), is always marked Prune=false and its values
# are left alone. It is taken over (both markers stripped, values written) only
# with IDENTITY_TAKEOVER_ENVCONFIG=1 AND when the tracking Application no longer
# wants it: absent from its .status.resources, or listed requiresPruning: true.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
fails=0
check() { if eval "$2"; then echo "ok - $1"; else echo "NOT OK - $1"; fails=$((fails+1)); fi; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/realm/clusters" "$work/bin"
printf 'environment: homelab\nrole: prod\nmaturity: durable\n' > "$work/realm/clusters/homelab-prod.yaml"
export STUB_LOG="$work/calls" STUB_LIVE_CLUSTER="" STUB_EC_PRESENT="" STUB_EC_LABEL="" STUB_EC_TID="" STUB_APP=""
# STUB_APP: "absent", or the status.resources entry for the EnvironmentConfig:
# "none" (not listed), "wanted" (listed), "prune" (listed, requiresPruning).
cat > "$work/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case "$*" in
  *"get configmap -n nordri cluster-identity -o jsonpath={.data.cluster}"*) printf '%s' "$STUB_LIVE_CLUSTER" ;;
  *"get configmap -n nordri cluster-identity -o jsonpath={.data.tailnetNode}"*) printf '' ;;
  *"get crd environmentconfigs.apiextensions.crossplane.io"*)
      if [[ -n "${STUB_NO_CRD:-}" ]]; then
          [[ "$*" == *--ignore-not-found* ]] && exit 0
          echo 'Error from server (NotFound): customresourcedefinitions.apiextensions.k8s.io "environmentconfigs.apiextensions.crossplane.io" not found' >&2; exit 1
      fi
      [[ -n "${STUB_CRD_ERR:-}" ]] && { echo 'Unable to connect to the server' >&2; exit 1; }
      printf 'customresourcedefinition.apiextensions.k8s.io/environmentconfigs.apiextensions.crossplane.io' ;;
  *"get environmentconfig cluster-identity"*)
      [[ -n "$STUB_EC_PRESENT" ]] || exit 0
      jq -n --arg l "$STUB_EC_LABEL" --arg t "$STUB_EC_TID" '{metadata: {name: "cluster-identity",
          labels: (if $l == "" then {} else {"app.kubernetes.io/instance": $l} end),
          annotations: (if $t == "" then {} else {"argocd.argoproj.io/tracking-id": $t} end)}}' ;;
  *"get application -n argo "*)
      case "$STUB_APP" in
        absent) ;;
        none) echo '{"status":{"resources":[{"kind":"ConfigMap","name":"other"}]}}' ;;
        wanted) echo '{"status":{"resources":[{"group":"apiextensions.crossplane.io","kind":"EnvironmentConfig","name":"cluster-identity","status":"Synced"}]}}' ;;
        prune) echo '{"status":{"resources":[{"group":"apiextensions.crossplane.io","kind":"EnvironmentConfig","name":"cluster-identity","status":"OutOfSync","requiresPruning":true}]}}' ;;
      esac ;;
  "apply -f -"|"apply -f - -n nordri"|*"apply -f -"*) cat >> "$STUB_LOG.applied" ;;
esac
exit 0
STUB
chmod +x "$work/bin/kubectl"
export PATH="$work/bin:$PATH"

run() { : > "$STUB_LOG"; : > "$STUB_LOG.applied"; REALM_DIR="$work/realm" bash "$root/scripts/identity.sh" "$@"; }
TID='layer4-fundamentals:apiextensions.crossplane.io/EnvironmentConfig:/cluster-identity'
written() { grep -q 'kind: EnvironmentConfig' "$STUB_LOG.applied"; }
marked() { grep -q 'annotate environmentconfig cluster-identity argocd.argoproj.io/sync-options=Prune=false --overwrite' "$STUB_LOG"; }
stripped_label() { grep -q 'label environmentconfig cluster-identity app.kubernetes.io/instance-' "$STUB_LOG"; }
stripped_tid() { grep -q 'annotate environmentconfig cluster-identity argocd.argoproj.io/tracking-id-' "$STUB_LOG"; }

# Fresh cluster, EnvironmentConfig absent: ConfigMap, Secret and a new EC.
STUB_LIVE_CLUSTER="" STUB_EC_PRESENT="" run apply realm-x homelab-prod >/dev/null 2>&1; rc=$?
check "apply succeeds on a fresh cluster" "[[ $rc -eq 0 ]]"
check "namespace nordri ensured" "grep -q 'create namespace nordri' \"\$STUB_LOG\""
check "ConfigMap carries the cluster" "grep -q '^  cluster: \"\\?homelab-prod\"\\?\$' \"\$STUB_LOG.applied\""
check "ConfigMap carries the merged storageClass" "grep -q '^  storageClass: \"\\?local-path\"\\?\$' \"\$STUB_LOG.applied\""
check "cluster Secret has the type label" "grep -q 'argocd.argoproj.io/secret-type: cluster' \"\$STUB_LOG.applied\""
check "cluster Secret has the cluster label" "grep -q 'nordri.siliconsaga.org/cluster: homelab-prod' \"\$STUB_LOG.applied\""
check "cluster Secret has the environment label" "grep -q 'nordri.siliconsaga.org/environment: homelab' \"\$STUB_LOG.applied\""
check "prod has a tailnet node, so tailnet=true" "grep -q 'nordri.siliconsaga.org/tailnet: \"true\"' \"\$STUB_LOG.applied\""
check "tailnet-node annotation" "grep -q 'nordri.siliconsaga.org/tailnet-node: \"\\?homelab-prod\"\\?' \"\$STUB_LOG.applied\""
check "in-cluster server" "grep -q 'server: https://kubernetes.default.svc' \"\$STUB_LOG.applied\""
check "EnvironmentConfig written" "written"
check "a written EC carries Prune=false" "grep -q 'argocd.argoproj.io/sync-options: \"\\?Prune=false\"\\?' \"\$STUB_LOG.applied\""

# Tracked by label, no take-over flag (migrate step 2): Prune=false, values untouched.
STUB_LIVE_CLUSTER="homelab-prod" STUB_EC_PRESENT=1 STUB_EC_LABEL="layer4-fundamentals" run apply realm-x homelab-prod >/dev/null 2>&1; rc=$?
check "label-tracked EC: apply exits 0" "[[ $rc -eq 0 ]]"
check "label-tracked EC gets Prune=false" "marked"
check "label-tracked EC is not rewritten without the take-over flag" "! written"
check "label-tracked EC keeps its label without the take-over flag" "! stripped_label"

# Tracked by annotation (ArgoCD 3.x default), no flag: Prune=false too, values untouched.
STUB_LIVE_CLUSTER="homelab-prod" STUB_EC_PRESENT=1 STUB_EC_TID="$TID" run apply realm-x homelab-prod >/dev/null 2>&1; rc=$?
check "annotation-tracked EC: apply exits 0" "[[ $rc -eq 0 ]]"
check "annotation-tracked EC gets Prune=false" "marked"
check "annotation-tracked EC is not rewritten without the take-over flag" "! written"
check "annotation-tracked EC keeps its tracking-id without the take-over flag" "! stripped_tid"

# Take-over requested, but ArgoCD still wants the object: refused, nothing changed.
STUB_LIVE_CLUSTER="homelab-prod" STUB_EC_PRESENT=1 STUB_EC_LABEL="layer4-fundamentals" STUB_APP=wanted IDENTITY_TAKEOVER_ENVCONFIG=1 run apply realm-x homelab-prod >/dev/null 2>"$work/err"; rc=$?
check "take-over while ArgoCD still lists the EC is refused (exit 1)" "[[ $rc -eq 1 ]]"
check "the refusal names the Application" "grep -q 'layer4-fundamentals' \"\$work/err\""
check "the tracking Application's status is read" "grep -q 'get application -n argo layer4-fundamentals' \"\$STUB_LOG\""
check "a refused take-over strips nothing" "! stripped_label && ! stripped_tid"
check "a refused take-over writes nothing" "! written"
check "a refused take-over still leaves Prune=false" "marked"

# Take-over, label tracking, ArgoCD no longer lists it: both markers handled, values written.
STUB_LIVE_CLUSTER="homelab-prod" STUB_EC_PRESENT=1 STUB_EC_LABEL="layer4-fundamentals" STUB_APP=none IDENTITY_TAKEOVER_ENVCONFIG=1 run apply realm-x homelab-prod >/dev/null 2>&1; rc=$?
check "take-over (label, not listed) exits 0" "[[ $rc -eq 0 ]]"
check "take-over strips the instance label" "stripped_label"
check "take-over rewrites the EC" "written"
check "the label is stripped before the write" "stripped_label && [[ \$(grep -n 'app.kubernetes.io/instance-' \"\$STUB_LOG\" | cut -d: -f1) -lt \$(grep -n '^apply -f -' \"\$STUB_LOG\" | tail -n 1 | cut -d: -f1) ]]"

# Take-over, annotation tracking, listed requiresPruning: the tracking-id goes.
STUB_LIVE_CLUSTER="homelab-prod" STUB_EC_PRESENT=1 STUB_EC_TID="$TID" STUB_APP=prune IDENTITY_TAKEOVER_ENVCONFIG=1 run apply realm-x homelab-prod >/dev/null 2>&1; rc=$?
check "take-over (tracking-id, requiresPruning) exits 0" "[[ $rc -eq 0 ]]"
check "take-over strips the tracking-id annotation" "stripped_tid"
check "take-over (tracking-id) rewrites the EC" "written"

# Take-over, both markers, the Application is gone: both stripped.
STUB_LIVE_CLUSTER="homelab-prod" STUB_EC_PRESENT=1 STUB_EC_LABEL="layer4-fundamentals" STUB_EC_TID="$TID" STUB_APP=absent IDENTITY_TAKEOVER_ENVCONFIG=1 run apply realm-x homelab-prod >/dev/null 2>&1; rc=$?
check "take-over (both markers, app absent) exits 0" "[[ $rc -eq 0 ]] && stripped_label && stripped_tid && written"

# Untracked and present: written, nothing to strip.
STUB_LIVE_CLUSTER="homelab-prod" STUB_EC_PRESENT=1 run apply realm-x homelab-prod >/dev/null 2>&1; rc=$?
check "an untracked EC is rewritten" "[[ $rc -eq 0 ]] && written"
check "an untracked EC needs no strip" "! stripped_label && ! stripped_tid"

# The name guard
STUB_LIVE_CLUSTER="homelab-test" run apply realm-x homelab-prod >/dev/null 2>"$work/err"; rc=$?
check "a different live cluster name is refused" "[[ $rc -eq 1 ]]"
check "the refusal names both" "grep -q 'homelab-test' \"\$work/err\" && grep -q 'homelab-prod' \"\$work/err\""

# Skip the EC projection on request
STUB_LIVE_CLUSTER="" STUB_EC_PRESENT="" IDENTITY_SKIP_ENVCONFIG=1 run apply realm-x homelab-prod >/dev/null 2>&1
check "IDENTITY_SKIP_ENVCONFIG skips the EC" "! grep -q 'kind: EnvironmentConfig' \"\$STUB_LOG.applied\""

# Important 7: without IDENTITY_SKIP_ENVCONFIG a missing CRD is an error, so
# bootstrap's second apply cannot finish with no EnvironmentConfig.
STUB_LIVE_CLUSTER="" STUB_NO_CRD=1 run apply realm-x homelab-prod >/dev/null 2>"$work/err"; rc=$?
check "a missing EnvironmentConfig CRD fails apply" "[[ $rc -ne 0 ]]"
check "the error names the CRD" "grep -q 'environmentconfigs.apiextensions.crossplane.io' \"\$work/err\""
STUB_LIVE_CLUSTER="" STUB_NO_CRD=1 IDENTITY_SKIP_ENVCONFIG=1 run apply realm-x homelab-prod >/dev/null 2>&1; rc=$?
check "with IDENTITY_SKIP_ENVCONFIG a missing CRD is fine" "[[ $rc -eq 0 ]]"
STUB_LIVE_CLUSTER="" STUB_CRD_ERR=1 run apply realm-x homelab-prod >/dev/null 2>&1; rc=$?
check "a failed CRD lookup fails apply, never reads as absent" "[[ $rc -ne 0 ]] && ! written"

echo "---"; [ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
