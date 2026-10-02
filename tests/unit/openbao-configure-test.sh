#!/usr/bin/env bash
# Unit test for lib/openbao.sh openbao_configure: with a kubectl stub standing
# in for the pod, assert the policies and roles it writes — in particular the
# forgejo-init policy (create-only KV writes under secret/forgejo) and the role
# bound to ServiceAccount forgejo-init in namespace forgejo (realm Forgejo
# day-2 Phase 2 design).
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"

fails=0
check() { if eval "$2"; then echo "ok - $1"; else echo "NOT OK - $1"; fails=$((fails+1)); fi; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/calls"
export STUB_CALLS="$work/calls"

cat > "$work/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
if [[ "$1 $2" == "get secret" ]]; then
    case "$*" in *jsonpath*) printf '%s' "stub-root" | base64 ;; esac
    exit 0
fi
if [[ "$1" == "exec" ]]; then
    # Drop the token line the lib prepends; keep the payload for assertions.
    IFS= read -r _token
    payload=$(cat)
    case "$*" in
        *"bao secrets list"*) printf '{"secret/":{"type":"kv","options":{"version":"2"}}}\n'; exit 0 ;;
        *"bao auth list"*) printf '{"kubernetes/":{"type":"kubernetes"}}\n'; exit 0 ;;
        *"bao kv metadata get secret/demo"*) exit 0 ;;
        *"bao policy write "*)
            name=$(printf '%s\n' "$*" | sed -n 's/.*bao policy write \([^ ]*\) .*/\1/p')
            printf '%s\n' "$payload" > "$STUB_CALLS/policy-$name"; exit 0 ;;
        *"bao write auth/kubernetes/role/"*)
            name=$(printf '%s\n' "$*" | sed -n 's|.*auth/kubernetes/role/\([^ ]*\) .*|\1|p')
            printf '%s\n' "$*" > "$STUB_CALLS/role-$name"; exit 0 ;;
        *"bao write auth/kubernetes/config"*) exit 0 ;;
    esac
fi
echo "unexpected kubectl $*" >&2; exit 97
STUB
chmod +x "$work/bin/kubectl"
export PATH="$work/bin:$PATH"

# shellcheck source=../../lib/openbao.sh
source "$root/lib/openbao.sh"
openbao_configure >/dev/null; rc=$?
check "openbao_configure succeeds against the stub" "[ $rc -eq 0 ]"

p="$STUB_CALLS/policy-forgejo-init"
check "forgejo-init policy is written" "[ -f '$p' ]"
check "policy: create-only on secret/data/forgejo (the root path)" "grep -Fq 'path \"secret/data/forgejo\" { capabilities = [\"create\"] }' '$p'"
check "policy: create-only on secret/data/forgejo/*" "grep -Fq 'path \"secret/data/forgejo/*\" { capabilities = [\"create\"] }' '$p'"
check "policy: read on secret/metadata/forgejo" "grep -Fq 'path \"secret/metadata/forgejo\" { capabilities = [\"read\"] }' '$p'"
check "policy: read on secret/metadata/forgejo/*" "grep -Fq 'path \"secret/metadata/forgejo/*\" { capabilities = [\"read\"] }' '$p'"
check "policy grants nothing else (4 path stanzas)" "[ \"\$(grep -c '^path ' '$p')\" -eq 4 ]"

r="$STUB_CALLS/role-forgejo-init"
check "forgejo-init role is written" "[ -f '$r' ]"
check "role binds ServiceAccount forgejo-init" "grep -Fq 'bound_service_account_names=forgejo-init' '$r'"
check "role binds namespace forgejo" "grep -Fq 'bound_service_account_namespaces=forgejo' '$r'"
check "role carries policy forgejo-init only" "grep -Fq 'policies=forgejo-init ' '$r'"

# The pre-existing roles are still written — this test guards against a
# refactor dropping one.
check "eso-role still written" "[ -f '$STUB_CALLS/role-eso-role' ]"
check "openbao-backup role still written" "[ -f '$STUB_CALLS/role-openbao-backup' ]"

[ "$fails" -eq 0 ] && echo "openbao-configure-test: PASS"
exit "$fails"
