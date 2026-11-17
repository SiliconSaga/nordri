#!/usr/bin/env bash
# shellcheck disable=SC2015
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
    if [[ -n "${STUB_GET_ERR_AFTER_PATCH:-}" && -e "$STUB_PATCH_BODY" ]]; then echo "Unable to connect to the server" >&2; exit 1; fi
    if [[ "$*" == *sync-options* ]]; then cat "$STUB_ANN" 2>/dev/null; exit 0; fi
    cat "$STUB_STATE"; exit 0 ;;
  annotate)
    if [[ -n "${STUB_ANNOTATE_FAIL:-}" ]]; then echo "annotate denied" >&2; exit 1; fi
    if [[ -n "${STUB_ANNOTATE_ERR:-}" ]]; then echo "$STUB_ANNOTATE_ERR" >&2; exit 1; fi
    for a in "$@"; do
      [[ "$a" == argocd.argoproj.io/sync-options=* ]] && printf '%s' "${a#*=}" > "$STUB_ANN"
      [[ "$a" == argocd.argoproj.io/sync-options- ]] && rm -f "$STUB_ANN"
    done
    exit 0 ;;
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
    ( for kv in "$@"; do export "${kv?}"; done; . "$root/lib/argo.sh"; argo_remove_finalizer demo ) > "$work/out" 2>&1
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

# The post-patch re-read must fail loud on its own, not lean on the caller's
# pipefail: bootstrap and update-embedded-git run without it.
printf '%s' "[\"$R\"]" > "$STUB_STATE"; : > "$STUB_LOG"; rm -f "$STUB_PATCH_BODY"
( set +o pipefail; export STUB_GET_ERR_AFTER_PATCH=1; . "$root/lib/argo.sh"; argo_remove_finalizer demo ) > "$work/out" 2>&1; rc=$?
check "a failed re-read after the patch returns 1 even without pipefail" "[[ $rc -eq 1 ]]"
check "a failed re-read is not reported as removed" "! grep -q 'resources finalizer removed' \"\$work/out\""

# argo_hold_prune: Prune=false on the Application, other sync options kept
export STUB_ANN="$work/ann"
hold() {
    printf '%s' "$1" > "$STUB_ANN"; shift; : > "$STUB_LOG"
    ( for kv in "$@"; do export "${kv?}"; done; . "$root/lib/argo.sh"; argo_hold_prune demo ) > "$work/out" 2>&1
}
hold ''; rc=$?
check "hold: no sync options yet → Prune=false" "[[ $rc -eq 0 && \"\$(cat \"\$STUB_ANN\")\" == 'Prune=false' ]]"
check "hold: the annotation is overwritten in place, not appended as a second key" "grep -q 'KUBECTL annotate application -n argo demo argocd.argoproj.io/sync-options=Prune=false --overwrite' \"\$STUB_LOG\""
hold 'ServerSideApply=true'; rc=$?
check "hold: an existing sync option is kept" "[[ $rc -eq 0 && \"\$(cat \"\$STUB_ANN\")\" == 'ServerSideApply=true,Prune=false' ]]"
hold 'Prune=false'; rc=$?
check "hold: already Prune=false is a no-op" "[[ $rc -eq 0 ]] && ! grep -q 'KUBECTL annotate' \"\$STUB_LOG\""
hold '' STUB_GET_ERR='Error from server (NotFound): applications.argoproj.io "demo" not found'; rc=$?
check "hold: NotFound means nothing to hold: returns 0" "[[ $rc -eq 0 ]] && ! grep -q 'KUBECTL annotate' \"\$STUB_LOG\""
hold '' STUB_GET_ERR='Unable to connect to the server: dial tcp: i/o timeout'; rc=$?
check "hold: any other get failure returns 1" "[[ $rc -eq 1 ]] && ! grep -q 'KUBECTL annotate' \"\$STUB_LOG\""
hold '' STUB_ANNOTATE_FAIL=1; rc=$?
check "hold: a failing annotate returns 1" "[[ $rc -eq 1 ]]"

# argo_release_prune: the sync-options annotation comes off again
release() {
    printf '%s' 'Prune=false' > "$STUB_ANN"; : > "$STUB_LOG"
    ( for kv in "$@"; do export "${kv?}"; done; . "$root/lib/argo.sh"; argo_release_prune demo ) > "$work/out" 2>&1
}
release; rc=$?
check "release: removes the annotation, returns 0" "[[ $rc -eq 0 && ! -e \"\$STUB_ANN\" ]]"
check "release: uses the trailing-dash removal form" "grep -q 'KUBECTL annotate application -n argo demo argocd.argoproj.io/sync-options-\$' \"\$STUB_LOG\""
release STUB_ANNOTATE_ERR='Error from server (NotFound): applications.argoproj.io "demo" not found'; rc=$?
check "release: NotFound is tolerated: returns 0" "[[ $rc -eq 0 ]]"
release STUB_ANNOTATE_ERR='Unable to connect to the server: dial tcp: i/o timeout'; rc=$?
check "release: any other error returns 1" "[[ $rc -eq 1 ]]"
check "release: the error is printed" "grep -q 'i/o timeout' \"\$work/out\""

# the refresh-consumed predicate: counts Applications still carrying the annotation (column 5)
pred_n() { ( . "$root/lib/argo.sh"; _pred_refresh_pending <<< "$1" ); }
check "predicate counts rows with the refresh annotation" "[[ \"\$(pred_n \$'a\tSynced\tHealthy\t\thard\nb\tSynced\tHealthy\t\t\n')\" == 1 ]]"
check "predicate is 0 when none carries it" "[[ \"\$(pred_n \$'a\tSynced\tHealthy\t\t\n')\" == 0 ]]"

# the operations-done predicate: .operation set (column 6) counts even while
# operationState.phase still shows the previous operation's result
ops_n() { ( . "$root/lib/argo.sh"; _pred_ops_done <<< "$1" ); }
check "ops: Running counts" "[[ \"\$(ops_n \$'a\tSynced\tHealthy\tRunning\t\t\n')\" == 1 ]]"
check "ops: .operation set before the phase reads Running counts" "[[ \"\$(ops_n \$'a\tSynced\tHealthy\tSucceeded\t\t{\"sync\":{}}\n')\" == 1 ]]"
check "ops: done with no .operation is 0" "[[ \"\$(ops_n \$'a\tSynced\tHealthy\tSucceeded\t\t\n')\" == 0 ]]"
check "the rows query carries .operation" "grep -qF '{.operation}' \"\$root/lib/argo.sh\""

echo "---"; [ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
