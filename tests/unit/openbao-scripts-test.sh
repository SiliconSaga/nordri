#!/usr/bin/env bash
# Unit test for openbao-init.sh and openbao-configure.sh argument handling and
# for lib/openbao.sh's OPENBAO_INIT_KEEP_FILE path, with a kubectl stub. The
# scripts' argument checks run before any cluster call; the keep-file check
# drives openbao_ensure_initialized through a stub that answers `bao status`
# (uninitialized), `bao operator init`, and the Secret create/read-back.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"

fails=0
check() { if eval "$2"; then echo "ok - $1"; else echo "NOT OK - $1"; fails=$((fails+1)); fi; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/realms/demo-realm" "$work/tmp"
export STUB_STATE="$work/state"
mkdir -p "$STUB_STATE"
# The lib's scratch directories land under TMPDIR; a private one keeps the
# "nothing left behind" assertion from seeing an unrelated run's directory.
export TMPDIR="$work/tmp"

cat > "$work/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
if [[ "$1 $2" == "config current-context" ]]; then
    [[ -n "${STUB_CTX:-}" ]] && printf '%s\n' "$STUB_CTX"
    exit 0
fi
if [[ "$1 $2" == "get pod" ]]; then printf 'Running'; exit 0; fi
if [[ "$1 $2" == "get secret" ]]; then
    [[ -f "$STUB_STATE/secret" ]] || exit 1
    case "$*" in *jsonpath*) printf '%s' "stub-root" | base64 ;; esac
    exit 0
fi
if [[ "$1 $2" == "create secret" ]]; then touch "$STUB_STATE/secret"; exit 0; fi
if [[ "$1" == "exec" ]]; then
    case "$*" in
        *"bao status"*)
            if [[ -f "$STUB_STATE/initialized" ]]; then
                printf '{"initialized":true,"sealed":false,"type":"static"}\n'; exit 0
            fi
            printf '{"initialized":false,"sealed":true,"type":"static"}\n'; exit 3 ;;
        *"bao operator init"*)
            # The real API refuses -key-shares under an auto seal and
            # -recovery-shares under Shamir; the stub is a static seal.
            printf '%s\n' "$*" > "$STUB_STATE/init-args"
            case "$*" in *-key-shares*) echo "Error initializing: parameters secret_shares,secret_threshold not applicable to seal type static" >&2; exit 2 ;; esac
            case "$*" in *-recovery-shares=3*-recovery-threshold=2*) ;; *) echo "stub: expected -recovery-shares=3 -recovery-threshold=2" >&2; exit 2 ;; esac
            touch "$STUB_STATE/initialized"
            printf '{"unseal_keys_b64":[],"recovery_keys_b64":["a","b","c"],"root_token":"stub-root"}\n'; exit 0 ;;
    esac
fi
echo "unexpected kubectl $*" >&2; exit 97
STUB
chmod +x "$work/bin/kubectl"
export PATH="$work/bin:$PATH"
gke_ctx="gke_teralivekubernetes_us-east1-d_ttf-cluster"

# --- openbao-init.sh argument handling (no cluster call reaches the stub) ---
bash "$root/openbao-init.sh" staging "$work/out.json" >/dev/null 2>&1; rc=$?
check "init: unknown target is refused" "[ $rc -eq 1 ]"
bash "$root/openbao-init.sh" gke >/dev/null 2>&1; rc=$?
check "init: missing output file is refused" "[ $rc -eq 1 ]"
touch "$work/exists.json"
STUB_CTX="$gke_ctx" bash "$root/openbao-init.sh" gke "$work/exists.json" >/dev/null 2>&1; rc=$?
check "init: existing output file is refused" "[ $rc -eq 1 ]"
check "init: existing output file is left alone" "[ ! -s '$work/exists.json' ]"
STUB_CTX="docker-desktop" bash "$root/openbao-init.sh" gke "$work/newdir/out.json" >/dev/null 2>&1; rc=$?
check "init: missing output directory is created before the context check refuses" "[ $rc -ne 0 ] && [ -d '$work/newdir' ]"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) echo "ok - init: created output directory is 0700 (skipped: no POSIX modes on $(uname -s))" ;;
    *) check "init: created output directory is 0700" "[ \"\$(stat -c %a '$work/newdir' 2>/dev/null || stat -f %Lp '$work/newdir')\" = 700 ]" ;;
esac
STUB_CTX="docker-desktop" bash "$root/openbao-init.sh" gke "$work/out.json" >/dev/null 2>&1; rc=$?
check "init: gke target on a local context is refused" "[ $rc -ne 0 ]"
check "init: refused run wrote no output file" "[ ! -e '$work/out.json' ]"

# --- openbao-init.sh end to end against the stub: keep-file lands 0600 ---
out="$(STUB_CTX="docker-desktop" bash "$root/openbao-init.sh" homelab "$work/out.json" 2>&1)"; rc=$?
check "init: fresh instance initializes" "[ $rc -eq 0 ]"
check "init: keep-file written" "[ -s '$work/out.json' ]"
check "init: keep-file holds the root token" "jq -e '.root_token == \"stub-root\"' '$work/out.json' >/dev/null"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        # Git Bash emulates POSIX modes; stat reports 644 for a file created
        # under umask 077, so the bit check would fail for the platform, not
        # the code. The umask+cp path is exercised above; the mode assertion
        # only means something on a real POSIX filesystem.
        echo "ok - init: keep-file is 0600 (skipped: no POSIX modes on $(uname -s))" ;;
    *)
        check "init: keep-file is 0600" "[ \"\$(stat -c %a '$work/out.json' 2>/dev/null || stat -f %Lp '$work/out.json')\" = 600 ]" ;;
esac
check "init: Secret was parked" "[ -f '$STUB_STATE/secret' ]"
check "init: auto seal used recovery shares, not key shares" "grep -q -- '-recovery-shares=3' '$STUB_STATE/init-args' && ! grep -q -- '-key-shares' '$STUB_STATE/init-args'"
check "init: output names the keep-file, not the material" "grep -q 'out.json' <<<'$out' && ! grep -q 'stub-root' <<<'$out'"
check "init: no scratch directory left behind" "[ -z \"\$(ls -A '$work/tmp')\" ]"

# An initialized instance is refused with exit 2, and nothing is written.
STUB_CTX="docker-desktop" bash "$root/openbao-init.sh" homelab "$work/again.json" >/dev/null 2>&1; rc=$?
check "init: already-initialized instance is refused with exit 2" "[ $rc -eq 2 ]"
check "init: refused re-init wrote nothing" "[ ! -e '$work/again.json' ]"

# --- openbao-configure.sh argument handling ---
bash "$root/openbao-configure.sh" staging >/dev/null 2>&1; rc=$?
check "configure: unknown target is refused" "[ $rc -eq 1 ]"
bash "$root/openbao-configure.sh" gke 'Bad_Realm' >/dev/null 2>&1; rc=$?
check "configure: non-DNS-label realm is refused" "[ $rc -eq 1 ]"
REALM_DIR="$work/realms/missing" bash "$root/openbao-configure.sh" gke missing >/dev/null 2>&1; rc=$?
check "configure: absent realm directory is refused" "[ $rc -eq 1 ]"
STUB_CTX="$gke_ctx" REALM_DIR="$work/realms/demo-realm" bash "$root/openbao-configure.sh" homelab demo-realm >/dev/null 2>&1; rc=$?
check "configure: homelab target on a GKE context is refused" "[ $rc -ne 0 ]"

echo "---"; [ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
