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
    # metadata get: present if pre-existing or written earlier in this run
    # (the stub remembers puts, so a second pass sees persisted state); an
    # explicit not-found message otherwise; a remote error for STUB_ERROR_PATH.
    # stderr is folded into stdout by the lib's snippet, so print the message.
    if [[ "$snippet" == *"bao kv metadata get"* ]]; then
        path="${snippet#*metadata get }"; path="${path%% *}"
        if [[ "$path" == "${STUB_ERROR_PATH:-}" ]]; then
            echo "Error making API request. Code: 503. Errors: * OpenBao is sealed"
            exit 2
        fi
        [[ "$path" == "$STUB_EXISTING" || -f "$STUB_PUTS/${path//\//_}.json" ]] && exit 0
        echo "No value found at secret/metadata/${path#secret/}"
        exit 2
    fi
    # kv put is create-only (-cas=0): a path already written answers with the
    # CAS conflict OpenBao 2.5.4 prints, exit 2, and keeps the first value.
    if [[ "$snippet" == *"bao kv put -cas=0 "* ]]; then
        path="${snippet#*kv put -cas=0 }"; path="${path%% *}"
        if [[ -f "$STUB_PUTS/${path//\//_}.json" ]]; then
            echo "Error writing data to ${path/secret\//secret/data/}: * check-and-set parameter did not match the current version"
            exit 2
        fi
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

# Second run against the persisted state is a no-op: the stub now reports the
# written path as present, so nothing is put again and the first value stands.
first_value="$(jq -r '."client-secret"' "$put")"
out2="$(openbao_seed_file "$work/seeds" 2>&1)"; rc=$?
check "second run succeeds" "[ $rc -eq 0 ]"
check "second run reports the seeded path present" "grep -q 'secret/new/thing present' <<<'$out2'"
check "second run leaves the first value in place" "[ \"\$(jq -r '.\"client-secret\"' '$put')\" = '$first_value' ]"
check "exactly one kv put across both runs" "[ \"\$(grep -c 'bao kv put' '$STUB_LOG')\" -eq 1 ]"
check "second run still skips the existing path" "[ ! -e '$STUB_PUTS/secret_already_there.json' ]"

# A remote error that is NOT not-found must never be read as absent: no write,
# non-zero return.
printf 'secret/flaky/path key\n' > "$work/flaky"
STUB_ERROR_PATH="secret/flaky/path" openbao_seed_file "$work/flaky" >/dev/null 2>&1; rc=$?
check "remote metadata error is an error, not absent" "[ $rc -ne 0 ]"
check "remote metadata error writes nothing" "[ ! -e '$STUB_PUTS/secret_flaky_path.json' ]"

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
# A glob in the key position must be rejected as the literal `*`, not expanded
# against the working directory into whatever filenames happen to match.
mkdir -p "$work/cwd"; touch "$work/cwd/innocent-key"
( cd "$work/cwd" && printf 'secret/glob *\n' > "$work/bad6" && openbao_seed_file "$work/bad6" >/dev/null 2>&1 ); rc=$?
check "a glob in the key position is an error, not expanded" "[ $rc -ne 0 ]"
# Validation covers the whole file before the first write: a valid absent
# path ahead of a malformed line must not be seeded.
printf 'secret/first/valid key\nsecret/lonely\n' > "$work/bad7"
openbao_seed_file "$work/bad7" >/dev/null 2>&1; rc=$?
check "malformed later line fails the whole file" "[ $rc -ne 0 ]"
check "earlier valid path was not written first" "[ ! -e '$STUB_PUTS/secret_first_valid.json' ]"
check "malformed files wrote nothing" "[ -z \"\$(ls -A '$STUB_PUTS')\" ]"
openbao_seed_file "$work/missing" >/dev/null 2>&1; rc=$?
check "missing seeds file is an error" "[ $rc -ne 0 ]"

echo "---"; [ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
