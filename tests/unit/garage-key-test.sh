#!/usr/bin/env bash
# Unit test for lib/garage.sh with a kubectl stub standing in for
# `kubectl exec ... /garage`. STUB_KEYS is the `key list` table body, one
# "<id> <created> <name> never" row per line; every create is logged so the
# test can assert that a re-run does not mint a second key.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/../../lib/garage.sh"

fails=0
check() { if eval "$2"; then echo "ok - $1"; else echo "NOT OK - $1"; fails=$((fails+1)); fi; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat > "$work/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
# kubectl exec -n garage garage-0 -- /garage <verb> <sub> [args]
[[ "$1" == "exec" ]] || { echo "unexpected kubectl $*" >&2; exit 97; }
shift 5
case "$2 $3" in
    "key list")
        [[ -n "${STUB_LIST_FAILS:-}" ]] && exit 1
        printf 'ID                          Created     Name                Expiration\r\n'
        if [[ -n "${STUB_KEYS:-}" ]]; then printf '%s\n' "$STUB_KEYS"; fi
        ;;
    "key create")
        echo "$4" >> "$STUB_LOG"
        printf 'Key name: %s\nKey ID: GKnew\nSecret key: newsecret\n' "$4"
        ;;
    "key info")
        [[ "$4" == "--show-secret" ]] || { echo "info without --show-secret" >&2; exit 98; }
        echo "$5" > "$STUB_INFO"
        printf 'Key ID: %s\nSecret key: oldsecret\n' "$5"
        ;;
    *) echo "unexpected garage $*" >&2; exit 97 ;;
esac
STUB
chmod +x "$work/bin/kubectl"
export PATH="$work/bin:$PATH"
export STUB_LOG="$work/creates.log" STUB_INFO="$work/info.arg"

: > "$STUB_LOG"
STUB_KEYS="" garage_key_ensure velero-service-key "$work/a" >/dev/null 2>&1; rc=$?
check "absent key is created" "[ $rc -eq 0 ] && grep -q 'Key ID: GKnew' '$work/a'"
check "absent key is created exactly once" "[ \$(wc -l < '$STUB_LOG') -eq 1 ]"

: > "$STUB_LOG"
STUB_KEYS="GKold  2026-09-16  velero-service-key  never" garage_key_ensure velero-service-key "$work/b" >/dev/null 2>&1; rc=$?
check "existing key is read back with its secret" "[ $rc -eq 0 ] && grep -q 'Secret key: oldsecret' '$work/b'"
check "existing key is not created again" "[ ! -s '$STUB_LOG' ]"
check "existing key is read back by its ID, not its name" "[ \"\$(cat '$STUB_INFO')\" = GKold ]"

# Another key whose name only starts the same sits beside the real one: the
# lookup must still read back the exact match, by ID.
: > "$STUB_LOG"
STUB_KEYS="GKdecoy  2026-09-15  velero-service-key-old  never
GKreal  2026-09-16  velero-service-key  never" garage_key_ensure velero-service-key "$work/b2" >/dev/null 2>&1; rc=$?
check "a prefix-sharing neighbour does not change which key is read" "[ $rc -eq 0 ] && grep -q 'Key ID: GKreal' '$work/b2'"

: > "$STUB_LOG"
STUB_KEYS="GKone  2026-09-16  velero-service-key  never
GKtwo  2026-09-17  velero-service-key  never" garage_key_ensure velero-service-key "$work/c" > "$work/c.out" 2>&1; rc=$?
check "duplicated name is refused" "[ $rc -ne 0 ]"
check "duplicated name creates nothing" "[ ! -s '$STUB_LOG' ]"
check "duplicated name names the delete fix" "grep -q 'key delete --yes' '$work/c.out'"

: > "$STUB_LOG"
STUB_KEYS="GKob  2026-09-17  openbao-backup-key  never" garage_key_ensure velero-service-key "$work/d" >/dev/null 2>&1; rc=$?
check "another key's name does not count as a match" "[ $rc -eq 0 ] && [ \$(wc -l < '$STUB_LOG') -eq 1 ]"

: > "$STUB_LOG"
STUB_KEYS="GKx  2026-09-17  velero-service-key-old  never" garage_key_ensure velero-service-key "$work/e" >/dev/null 2>&1; rc=$?
check "a name that only starts the same does not count as a match" "[ $rc -eq 0 ] && [ \$(wc -l < '$STUB_LOG') -eq 1 ]"

: > "$STUB_LOG"
STUB_LIST_FAILS=1 garage_key_ensure velero-service-key "$work/f" >/dev/null 2>&1; rc=$?
check "an unreadable key list is refused rather than creating blind" "[ $rc -ne 0 ] && [ ! -s '$STUB_LOG' ]"

# Git Bash on Windows reports every file as 644, so the mode is only checked
# where it means something.
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) echo "skip - key file mode (no POSIX modes on Windows)" ;;
    *)
        STUB_KEYS="" garage_key_ensure velero-service-key "$work/g" >/dev/null 2>&1
        mode=$(stat -c '%a' "$work/g" 2>/dev/null || stat -f '%Lp' "$work/g")
        check "the key file is owner-only" "[ '$mode' = '600' ]"
        ;;
esac

echo "---"; [ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
