#!/usr/bin/env bash
# Unit test for lib/openbao.sh's realm-seed parser and write logic, with a
# kubectl stub standing in for the cluster. The stub answers the two calls
# the seeding path makes — the parked-token read and `exec -i … sh -c` — and
# records what reached the pod, so the test can assert that an existing path
# is left alone, an absent path is written once with every declared key, the
# values are generated (non-empty, distinct), and malformed lines fail fast.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/../../lib/openbao.sh"

fails=0
check() { if eval "$2"; then echo "ok - $1"; else echo "NOT OK - $1"; fails=$((fails+1)); fi; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
export STUB_LOG="$work/exec.log" STUB_PUTS="$work/puts" STUB_EXISTING="secret/already/there"
mkdir -p "$STUB_PUTS"

cat > "$work/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
# get secret … : an existence check (no -o) or the jsonpath root_token read
if [[ "$1" == "get" && "$2" == "secret" ]]; then
    case "$*" in
        *jsonpath*) printf '%s' "dummy-root-token" | base64 ;;
    esac
    exit 0
fi
# exec -i -n ns pod -- sh -c '<snippet>' : stdin line 1 is the token, rest is payload
if [[ "$1" == "exec" ]]; then
    snippet="${@: -1}"
    IFS= read -r token
    payload="$(cat)"
    printf '%s\n' "$snippet" >> "$STUB_LOG"
    [[ "$token" == "dummy-root-token" ]] || { echo "bad token" >&2; exit 99; }
    if [[ "$snippet" == *"bao kv metadata get"* ]]; then
        path="${snippet#*metadata get }"; path="${path%% *}"
        [[ "$path" == "$STUB_EXISTING" ]] && exit 0
        exit 2
    fi
    if [[ "$snippet" == *"bao kv put"* ]]; then
        path="${snippet#*kv put }"; path="${path%% *}"
        printf '%s' "$payload" > "$STUB_PUTS/${path//\//_}.json"
        exit 0
    fi
    echo "unexpected snippet: $snippet" >&2
    exit 98
fi
echo "unexpected kubectl $*" >&2
exit 97
STUB
chmod +x "$work/bin/kubectl"
export PATH="$work/bin:$PATH"

# A realistic seeds file: comment, blank line, a tab-only line, an existing
# path, an absent one.
printf '# realm-owned OpenBao seeds\nsecret/already/there some-key\n\n\t \t\nsecret/new/thing client-secret dev-user-password   # trailing comment\n' > "$work/seeds"

out="$(openbao_seed_file "$work/seeds" 2>&1)"; rc=$?
check "seeding succeeds" "[ $rc -eq 0 ]"
check "existing path reported present" "grep -q 'secret/already/there present' <<<'$out'"
check "existing path never written" "[ ! -e '$STUB_PUTS/secret_already_there.json' ]"
check "absent path written once" "[ -f '$STUB_PUTS/secret_new_thing.json' ]"
check "absent path reported seeded" "grep -q 'secret/new/thing seeded (2 generated' <<<'$out'"
put="$STUB_PUTS/secret_new_thing.json"
check "put carries client-secret" "jq -e '.\"client-secret\" | length > 20' '$put' >/dev/null"
check "put carries dev-user-password" "jq -e '.\"dev-user-password\" | length > 20' '$put' >/dev/null"
check "generated values differ" "[ \"\$(jq -r '.\"client-secret\"' '$put')\" != \"\$(jq -r '.\"dev-user-password\"' '$put')\" ]"
check "exactly two keys written" "[ \"\$(jq 'keys | length' '$put')\" -eq 2 ]"
check "no CR in generated values" "! grep -q \$'\\r' '$put'"

# Second run is a no-op: nothing else is written.
rm -f "$put"
openbao_seed_file "$work/seeds" >/dev/null 2>&1
check "second run writes again only what is absent (stub still says absent)" "[ -f '$put' ]"
check "second run still skips the existing path" "[ ! -e '$STUB_PUTS/secret_already_there.json' ]"

# Malformed lines fail fast, before any write.
rm -rf "$STUB_PUTS"; mkdir -p "$STUB_PUTS"
printf 'secret/lonely\n' > "$work/bad1"
openbao_seed_file "$work/bad1" >/dev/null 2>&1; rc=$?
check "path with no keys is an error" "[ $rc -ne 0 ]"
printf 'notsecret/x key\n' > "$work/bad2"
openbao_seed_file "$work/bad2" >/dev/null 2>&1; rc=$?
check "path outside secret/ is an error" "[ $rc -ne 0 ]"
printf 'secret/../sys key\n' > "$work/bad3"
openbao_seed_file "$work/bad3" >/dev/null 2>&1; rc=$?
check "path with .. is an error" "[ $rc -ne 0 ]"
printf "secret/x'; id; echo ' key\n" > "$work/bad4"
openbao_seed_file "$work/bad4" >/dev/null 2>&1; rc=$?
check "path with shell metacharacters is an error" "[ $rc -ne 0 ]"
printf 'secret/x $(id)\n' > "$work/bad5"
openbao_seed_file "$work/bad5" >/dev/null 2>&1; rc=$?
check "key with shell metacharacters is an error" "[ $rc -ne 0 ]"
check "malformed files wrote nothing" "[ -z \"\$(ls -A '$STUB_PUTS')\" ]"
openbao_seed_file "$work/missing" >/dev/null 2>&1; rc=$?
check "missing seeds file is an error" "[ $rc -ne 0 ]"

echo "---"; [ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
