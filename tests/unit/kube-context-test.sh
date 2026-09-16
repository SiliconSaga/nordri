#!/usr/bin/env bash
# Unit test for lib/kube-context.sh with a kubectl stub whose current context
# is whatever STUB_CTX says. Covers the shape check per target, the explicit
# KUBE_CONTEXT match, and the no-context case.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/../../lib/kube-context.sh"

fails=0
check() { if eval "$2"; then echo "ok - $1"; else echo "NOT OK - $1"; fails=$((fails+1)); fi; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat > "$work/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
if [[ "$1 $2" == "config current-context" ]]; then
    [[ -n "${STUB_CTX:-}" ]] && printf '%s\n' "$STUB_CTX"
    exit 0
fi
echo "unexpected kubectl $*" >&2; exit 97
STUB
chmod +x "$work/bin/kubectl"
export PATH="$work/bin:$PATH"
gke_ctx="gke_teralivekubernetes_us-east1-d_ttf-cluster"

STUB_CTX="$gke_ctx" require_kube_context gke >/dev/null 2>&1; rc=$?
check "gke target on a GKE context passes" "[ $rc -eq 0 ]"
STUB_CTX="docker-desktop" require_kube_context homelab >/dev/null 2>&1; rc=$?
check "homelab target on a local context passes" "[ $rc -eq 0 ]"
STUB_CTX="docker-desktop" require_kube_context gke >/dev/null 2>&1; rc=$?
check "gke target on a local context is refused" "[ $rc -ne 0 ]"
STUB_CTX="$gke_ctx" require_kube_context homelab >/dev/null 2>&1; rc=$?
check "homelab target on a GKE context is refused" "[ $rc -ne 0 ]"
STUB_CTX="" require_kube_context gke >/dev/null 2>&1; rc=$?
check "no current context is refused" "[ $rc -ne 0 ]"
STUB_CTX="$gke_ctx" KUBE_CONTEXT="$gke_ctx" require_kube_context gke >/dev/null 2>&1; rc=$?
check "KUBE_CONTEXT matching the current context passes" "[ $rc -eq 0 ]"
STUB_CTX="docker-desktop" KUBE_CONTEXT="$gke_ctx" require_kube_context gke >/dev/null 2>&1; rc=$?
check "KUBE_CONTEXT differing from the current context is refused" "[ $rc -ne 0 ]"
STUB_CTX="docker-desktop" KUBE_CONTEXT="$gke_ctx" require_kube_context gke > "$work/mismatch.out" 2>&1
check "mismatch names the use-context fix" "grep -q 'kubectl config use-context gke_teralivekubernetes' '$work/mismatch.out'"
STUB_CTX="rancher-desktop" KUBE_CONTEXT="rancher-desktop" require_kube_context homelab >/dev/null 2>&1; rc=$?
check "explicit homelab context passes" "[ $rc -eq 0 ]"
require_kube_context staging >/dev/null 2>&1; rc=$?
check "unknown target is refused" "[ $rc -ne 0 ]"

echo "---"; [ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
