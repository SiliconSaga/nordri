#!/usr/bin/env bash
# Unit test for scripts/identity.sh apply: the ConfigMap, the in-cluster
# Secret's labels and annotations, the EnvironmentConfig handover (annotate
# only while ArgoCD still tracks it; take over once it does not), and the
# cluster-name guard. kubectl is a recording stub.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
fails=0
check() { if eval "$2"; then echo "ok - $1"; else echo "NOT OK - $1"; fails=$((fails+1)); fi; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/realm/clusters" "$work/bin"
printf 'environment: homelab\nrole: prod\nmaturity: durable\n' > "$work/realm/clusters/homelab-prod.yaml"
export STUB_LOG="$work/calls" STUB_LIVE_CLUSTER="" STUB_EC_TRACKED="" STUB_EC_PRESENT=""
cat > "$work/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case "$*" in
  *"get configmap -n nordri cluster-identity -o jsonpath={.data.cluster}"*) printf '%s' "$STUB_LIVE_CLUSTER" ;;
  *"get configmap -n nordri cluster-identity -o jsonpath={.data.tailnetNode}"*) printf '' ;;
  *"get crd environmentconfigs.apiextensions.crossplane.io"*) exit 0 ;;
  *"get environmentconfig cluster-identity -o jsonpath={.metadata.labels.app\.kubernetes\.io/instance}"*)
      [[ -n "$STUB_EC_PRESENT" ]] || exit 1; printf '%s' "$STUB_EC_TRACKED" ;;
  "apply -f -"|"apply -f - -n nordri"|*"apply -f -"*) cat >> "$STUB_LOG.applied" ;;
esac
exit 0
STUB
chmod +x "$work/bin/kubectl"
export PATH="$work/bin:$PATH"

run() { : > "$STUB_LOG"; : > "$STUB_LOG.applied"; REALM_DIR="$work/realm" bash "$root/scripts/identity.sh" "$@"; }

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
check "EnvironmentConfig written" "grep -q 'kind: EnvironmentConfig' \"\$STUB_LOG.applied\""

# EC present and still tracked by ArgoCD: annotate Prune=false, do not write it.
STUB_LIVE_CLUSTER="homelab-prod" STUB_EC_PRESENT=1 STUB_EC_TRACKED="layer4-fundamentals" run apply realm-x homelab-prod >/dev/null 2>&1
check "tracked EC gets Prune=false" "grep -q 'annotate environmentconfig cluster-identity argocd.argoproj.io/sync-options=Prune=false --overwrite' \"\$STUB_LOG\""
check "tracked EC is not rewritten" "! grep -q 'kind: EnvironmentConfig' \"\$STUB_LOG.applied\""

# EC present and untracked: take it over, strip tracking metadata.
STUB_LIVE_CLUSTER="homelab-prod" STUB_EC_PRESENT=1 STUB_EC_TRACKED="" run apply realm-x homelab-prod >/dev/null 2>&1
check "untracked EC is rewritten" "grep -q 'kind: EnvironmentConfig' \"\$STUB_LOG.applied\""
check "tracking label removed" "grep -q 'label environmentconfig cluster-identity app.kubernetes.io/instance-' \"\$STUB_LOG\""
check "prune annotation removed" "grep -q 'annotate environmentconfig cluster-identity argocd.argoproj.io/sync-options-' \"\$STUB_LOG\""

# The name guard
STUB_LIVE_CLUSTER="homelab-test" run apply realm-x homelab-prod >/dev/null 2>"$work/err"; rc=$?
check "a different live cluster name is refused" "[[ $rc -eq 1 ]]"
check "the refusal names both" "grep -q 'homelab-test' \"\$work/err\" && grep -q 'homelab-prod' \"\$work/err\""

# Skip the EC projection on request
STUB_LIVE_CLUSTER="" STUB_EC_PRESENT="" IDENTITY_SKIP_ENVCONFIG=1 run apply realm-x homelab-prod >/dev/null 2>&1
check "IDENTITY_SKIP_ENVCONFIG skips the EC" "! grep -q 'kind: EnvironmentConfig' \"\$STUB_LOG.applied\""

echo "---"; [ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
