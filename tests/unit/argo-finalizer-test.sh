#!/usr/bin/env bash
# Unit test for lib/argo.sh argo_remove_finalizer and argo_wait_refresh_consumed's
# predicate, against a recording kubectl stub that keeps the Application's
# finalizers in a state file. The helper must fail loud, keep every finalizer
# that is not ArgoCD's resources finalizer, and never succeed while one remains.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
fails=0
check() { if eval "$2"; then echo "ok - $1"; else echo "NOT OK - $1"; fails=$((fails+1)); fi; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat > "$work/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
echo "KUBECTL $*" >> "$STUB_LOG"
case "$1" in
  get)
    if [[ -n "${STUB_GET_ERR:-}" ]]; then echo "$STUB_GET_ERR" >&2; exit 1; fi
    cat "$STUB_STATE"; exit 0 ;;
  patch)
    if [[ -n "${STUB_PATCH_FAIL:-}" ]]; then echo "patch denied" >&2; exit 1; fi
    body=""; while [[ $# -gt 0 ]]; do [[ "$1" == -p ]] && body="$2"; shift; done
    printf '%s' "$body" > "$STUB_PATCH_BODY"
    [[ -n "${STUB_PATCH_NOOP:-}" ]] || printf '%s' "$(printf '%s' "$body" | jq -c '.metadata.finalizers')" > "$STUB_STATE"
    exit 0 ;;
esac
exit 0
STUB
chmod +x "$work/bin/kubectl"
export PATH="$work/bin:$PATH"
export STUB_LOG="$work/log" STUB_STATE="$work/state" STUB_PATCH_BODY="$work/body"

# run <state> [ENV=val ...]: returns the helper's status; output in $work/out
run() {
    local state="$1"; shift
    printf '%s' "$state" > "$STUB_STATE"; : > "$STUB_LOG"; rm -f "$STUB_PATCH_BODY"
    ( for kv in "$@"; do export "$kv"; done; . "$root/lib/argo.sh"; argo_remove_finalizer demo ) > "$work/out" 2>&1
}
R='resources-finalizer.argocd.argoproj.io'

run '' STUB_GET_ERR='Error from server (NotFound): applications.argoproj.io "demo" not found'; rc=$?
check "NotFound means nothing to adopt: returns 0" "[[ $rc -eq 0 ]] && [[ ! -e \"\$STUB_PATCH_BODY\" ]]"

run '' STUB_GET_ERR='Unable to connect to the server: dial tcp: i/o timeout'; rc=$?
check "any other get failure returns 1" "[[ $rc -eq 1 ]]"
check "the get error is printed" "grep -q 'i/o timeout' \"\$work/out\""
check "no patch after a failed get" "! grep -q 'KUBECTL patch' \"\$STUB_LOG\""

run ''; rc=$?
check "no finalizers: returns 0 without patching" "[[ $rc -eq 0 ]] && ! grep -q 'KUBECTL patch' \"\$STUB_LOG\""

run '["other.example/keep"]'; rc=$?
check "only a foreign finalizer: returns 0 without patching" "[[ $rc -eq 0 ]] && ! grep -q 'KUBECTL patch' \"\$STUB_LOG\""

run "[\"$R\"]"; rc=$?
check "sole resources finalizer is removed" "[[ $rc -eq 0 ]] && [[ \"\$(jq -c .metadata.finalizers \"\$STUB_PATCH_BODY\")\" == '[]' ]]"

run "[\"$R\",\"other.example/keep\"]"; rc=$?
check "resources plus another finalizer: returns 0" "[[ $rc -eq 0 ]]"
check "the patch keeps other.example/keep" "[[ \"\$(jq -c .metadata.finalizers \"\$STUB_PATCH_BODY\")\" == '[\"other.example/keep\"]' ]]"
check "the patch drops the resources finalizer" "! grep -q 'resources-finalizer' \"\$STUB_PATCH_BODY\""
check "the patch is a merge patch" "grep -q 'patch.*--type[ =]merge' \"\$STUB_LOG\""

run "[\"other.example/first\",\"$R/background\",\"other.example/last\"]"; rc=$?
check "the /background variant goes, order of the rest is kept" "[[ $rc -eq 0 ]] && [[ \"\$(jq -c .metadata.finalizers \"\$STUB_PATCH_BODY\")\" == '[\"other.example/first\",\"other.example/last\"]' ]]"

run "[\"$R\"]" STUB_PATCH_FAIL=1; rc=$?
check "a failing patch returns 1" "[[ $rc -eq 1 ]]"

run "[\"$R\",\"other.example/keep\"]" STUB_PATCH_NOOP=1; rc=$?
check "a finalizer still present after the patch returns 1" "[[ $rc -eq 1 ]]"

# the refresh-consumed predicate: counts Applications still carrying the annotation (column 5)
pred_n() { ( . "$root/lib/argo.sh"; _pred_refresh_pending <<< "$1" ); }
check "predicate counts rows with the refresh annotation" "[[ \"\$(pred_n \$'a\tSynced\tHealthy\t\thard\nb\tSynced\tHealthy\t\t\n')\" == 1 ]]"
check "predicate is 0 when none carries it" "[[ \"\$(pred_n \$'a\tSynced\tHealthy\t\t\n')\" == 0 ]]"

echo "---"; [ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
