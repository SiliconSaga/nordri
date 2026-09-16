# components/nordri/lib/openbao.sh
# Bring a freshly deployed OpenBao from "pod Running" to "usable by the stack"
# without a human in the loop: init, unseal, the one-time mount/auth/policy
# configuration External Secrets depends on, and realm-declared seed values.
# Sourced by bootstrap.sh (Layer 5b). Every function returns non-zero on
# failure.
#
# Why this exists: a fresh homelab on 2026-09-15 came up with every layer
# green and Keycloak's realm import still could not run, because three steps
# were still hands — `bao operator init`, the KV/auth/policy setup from the
# realm plan (Task A1.5), and seeding secret/leidangr/oidc. Each was scripted
# on the spot; this is that script made durable, in the shape Layer 5 already
# uses for Garage and Velero.
#
# Secret hygiene, the rule this file follows throughout: no key material in an
# argument list and no key material in a shell variable. The root token and
# unseal shares move pod → Secret → pod as pipes, and the one place a value
# has to rest — init output before the Secret exists, generated seed values
# before the put — is a 0600 file in a 0700 directory that is removed on
# success and deliberately left behind (and named) on failure, because init
# is irreversible: losing its output loses the vault.
#
# Custody: the init material is parked in the in-cluster `openbao-init` Secret,
# which is the homelab posture realm ADR 0002 accepts (anyone who can read
# Secrets in `openbao` owns the vault). On a live environment the shares belong
# in the operator's password manager FIRST, which is why bootstrap runs the
# init half on gke only when OPENBAO_AUTO_INIT=1 is set deliberately.

OPENBAO_NS="${OPENBAO_NS:-openbao}"
OPENBAO_POD="${OPENBAO_POD:-openbao-0}"
OPENBAO_INIT_SECRET="${OPENBAO_INIT_SECRET:-openbao-init}"

# Wait until the OpenBao pod is Running AND its API answers `bao status`.
# Ready is not the bar (an uninitialized or sealed pod is Running and NotReady
# by design), but Running alone is not enough either: the process can still be
# starting, and a status call that fails then would skip init silently.
# openbao_wait_running <timeout-seconds>
openbao_wait_running() {
    local timeout="${1:-600}" start elapsed phase
    start=$(date +%s)
    while true; do
        phase=$(kubectl get pod -n "$OPENBAO_NS" "$OPENBAO_POD" -o jsonpath='{.status.phase}' 2>/dev/null) || phase=""
        if [[ "$phase" == "Running" ]] && openbao_status_json >/dev/null 2>&1; then
            return 0
        fi
        elapsed=$(( $(date +%s) - start ))
        if (( elapsed > timeout )); then
            echo "⚠️  openbao_wait_running: $OPENBAO_POD not answering after ${timeout}s (phase: ${phase:-absent})." >&2
            return 1
        fi
        echo "   ... waiting for $OPENBAO_POD to be Running and answering ($elapsed/${timeout}s)"
        sleep 10
    done
}

# `bao status -format=json` exits 0 unsealed, 2 sealed, and emits JSON either
# way; anything else is a real failure. Prints the JSON.
openbao_status_json() {
    local out rc=0
    out=$(kubectl exec -n "$OPENBAO_NS" "$OPENBAO_POD" -- bao status -format=json 2>/dev/null) || rc=$?
    case "$rc" in
        0|2) printf '%s\n' "$out" ;;
        *)
            echo "❌ openbao_status_json: bao status failed (exit $rc) — is the pod up?" >&2
            return 1
            ;;
    esac
}

# openbao_status_field <jq-filter>  e.g. '.initialized', '.sealed', '.type'
openbao_status_field() {
    openbao_status_json | jq -r "$1"
}

# Stream the parked root token to stdout. A pipe, never a variable: callers
# splice this into the pod's stdin.
openbao_root_token_stream() {
    kubectl get secret -n "$OPENBAO_NS" "$OPENBAO_INIT_SECRET" -o jsonpath='{.data.root_token}' | base64 -d
}

# Run a shell snippet inside the pod with BAO_TOKEN set from the parked root
# token. The token is stdin line 1; the caller's own stdin follows it, so
# `bao policy write name -` and `bao kv put path -` read their bodies as usual.
# openbao_run_with_token <sh-snippet>   (stdin: payload for the snippet, if any)
openbao_run_with_token() {
    local snippet="$1"
    if ! kubectl get secret -n "$OPENBAO_NS" "$OPENBAO_INIT_SECRET" >/dev/null 2>&1; then
        echo "❌ openbao_run_with_token: Secret $OPENBAO_NS/$OPENBAO_INIT_SECRET is missing." >&2
        return 1
    fi
    {
        openbao_root_token_stream
        printf '\n'
        cat
    } | kubectl exec -i -n "$OPENBAO_NS" "$OPENBAO_POD" -- sh -c "IFS= read -r BAO_TOKEN; export BAO_TOKEN; $snippet"
}

# Does a KV v2 path exist? Prints `present` or `absent`; returns 1 for any
# other outcome. `bao kv metadata get` exits 2 for every remote error, not just
# a missing path, so the exit code alone cannot decide — an API, TLS or auth
# failure read as "absent" would lead straight to overwriting a live value.
# Only the explicit "No value found" message counts as absent.
# openbao_kv_path_state <secret/path>
openbao_kv_path_state() {
    local path="$1" out rc=0
    out=$(openbao_run_with_token "bao kv metadata get $path 2>&1 >/dev/null" </dev/null) || rc=$?
    if [[ $rc -eq 0 ]]; then
        echo present
    elif [[ $rc -eq 2 && "$out" == *"No value found"* ]]; then
        echo absent
    else
        echo "❌ openbao_kv_path_state: metadata get $path failed (exit $rc): ${out:-no output}" >&2
        return 1
    fi
}

# A private scratch directory: 0700, under the caller's TMPDIR, removed by the
# caller. Prints the path.
openbao_scratch_dir() {
    local d
    d=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/openbao-XXXXXX") || return 1
    printf '%s\n' "$d"
}

# Initialize if needed and park the init material. Init is the one
# irreversible step here, so its output is written to a 0600 file BEFORE the
# Secret is created, and that file is removed only after the Secret reads back
# with a root_token. If anything in between fails, the file stays and its path
# is printed: the shares exist exactly once at that moment, and losing them
# means wiping the vault.
#
# A leftover openbao-init Secret next to an UNinitialized instance means the
# PVC was wiped (a reset homelab, the documented "lost the shares" recovery):
# the stale material is kept under a timestamped name, and a fresh init
# proceeds.
openbao_ensure_initialized() {
    local initialized
    initialized=$(openbao_status_field '.initialized') || return 1
    if [[ "$initialized" == "true" ]]; then
        echo "   ✅ OpenBao already initialized."
        return 0
    fi
    if kubectl get secret -n "$OPENBAO_NS" "$OPENBAO_INIT_SECRET" >/dev/null 2>&1; then
        local stale="${OPENBAO_INIT_SECRET}-stale-$(date +%Y%m%d%H%M%S)"
        echo "   ⚠️  $OPENBAO_INIT_SECRET exists but the instance is uninitialized (wiped storage?) — keeping it as $stale."
        kubectl get secret -n "$OPENBAO_NS" "$OPENBAO_INIT_SECRET" -o json \
            | jq --arg n "$stale" '{apiVersion, kind, type, data, metadata: {name: $n, namespace: .metadata.namespace}}' \
            | kubectl apply -f - >/dev/null || return 1
        kubectl delete secret -n "$OPENBAO_NS" "$OPENBAO_INIT_SECRET" >/dev/null || return 1
    fi

    local scratch
    scratch=$(openbao_scratch_dir) || return 1
    echo "   🔐 Initializing OpenBao (3 shares, threshold 2); init output goes to $scratch/init.json (0600) until the Secret is confirmed..."
    if ! kubectl exec -n "$OPENBAO_NS" "$OPENBAO_POD" -- bao operator init -key-shares=3 -key-threshold=2 -format=json > "$scratch/init.json"; then
        echo "❌ openbao_ensure_initialized: bao operator init failed." >&2
        rm -rf "$scratch"
        return 1
    fi
    if ! jq -r '.root_token' "$scratch/init.json" > "$scratch/root_token" || [[ ! -s "$scratch/root_token" ]]; then
        echo "❌ openbao_ensure_initialized: init output has no root_token. THE INIT MATERIAL IS AT $scratch/init.json — do not lose it." >&2
        return 1
    fi
    if ! kubectl create secret generic "$OPENBAO_INIT_SECRET" -n "$OPENBAO_NS" \
            --from-file=init.json="$scratch/init.json" \
            --from-file=root_token="$scratch/root_token" >/dev/null; then
        echo "❌ openbao_ensure_initialized: creating Secret $OPENBAO_NS/$OPENBAO_INIT_SECRET failed. THE INIT MATERIAL IS AT $scratch/init.json — park it by hand, then re-run." >&2
        return 1
    fi
    # Read back before discarding the only other copy.
    if [[ -z "$(kubectl get secret -n "$OPENBAO_NS" "$OPENBAO_INIT_SECRET" -o jsonpath='{.data.root_token}' 2>/dev/null)" ]]; then
        echo "❌ openbao_ensure_initialized: Secret created but reads back without root_token. THE INIT MATERIAL IS AT $scratch/init.json." >&2
        return 1
    fi
    rm -rf "$scratch"
    echo "   ✅ Initialized; material parked in Secret $OPENBAO_NS/$OPENBAO_INIT_SECRET. With seal: auto the shares are recovery keys; with shamir they unseal (next)."
}

# Unseal a sealed Shamir instance from the parked shares. A sealed instance on
# an auto seal is a broken seal backend, which no share can fix — say so.
openbao_ensure_unsealed() {
    local sealed type
    sealed=$(openbao_status_field '.sealed') || return 1
    if [[ "$sealed" != "true" ]]; then
        echo "   ✅ OpenBao unsealed."
        return 0
    fi
    type=$(openbao_status_field '.type')
    if [[ "$type" != "shamir" ]]; then
        echo "❌ OpenBao is sealed on seal type '$type' — auto-unseal did not complete. Check the seal backend (nidavellir docs/secrets-management.md); shares cannot help here." >&2
        return 1
    fi
    echo "   🔓 Unsealing (shamir) with two parked shares..."
    local i
    for i in 0 1; do
        kubectl get secret -n "$OPENBAO_NS" "$OPENBAO_INIT_SECRET" -o jsonpath='{.data.init\.json}' \
            | base64 -d \
            | jq -r ".unseal_keys_b64[$i]" \
            | kubectl exec -i -n "$OPENBAO_NS" "$OPENBAO_POD" -- sh -c 'IFS= read -r s; bao operator unseal "$s" >/dev/null' || return 1
    done
    sealed=$(openbao_status_field '.sealed')
    if [[ "$sealed" == "true" ]]; then
        echo "❌ openbao_ensure_unsealed: still sealed after two shares." >&2
        return 1
    fi
    echo "   ✅ Unsealed."
}

# The one-time configuration External Secrets needs (realm plan Task A1.5
# Steps 3-4): KV v2 at secret/, Kubernetes auth trusting the in-cluster API,
# the read-only eso-read policy, the eso-role bound to ESO's ServiceAccount,
# and the secret/demo canary. Idempotent: an existing secret/ mount is accepted
# only if it is KV v2 (the eso-read policy grants secret/data/*, which a KV v1
# mount never serves), an existing auth method is left alone, policy and role
# are rewritten to the same content, the canary is seeded only when absent.
openbao_configure() {
    echo "   • KV v2 at secret/"
    # Reported as "<type>,<version>" — no slash in the jq program, because Git
    # Bash rewrites a bare "/" argument into a Windows path. MSYS_NO_PATHCONV
    # pins the rest (the mount name carries one).
    local mount
    mount=$(openbao_run_with_token 'bao secrets list -format=json' </dev/null \
        | MSYS_NO_PATHCONV=1 jq -r '.["secret/"] | if . == null then "absent" else ([.type, (.options.version // "1")] | join(",")) end') || return 1
    case "$mount" in
        absent)
            openbao_run_with_token 'bao secrets enable -version=2 -path=secret kv >/dev/null' </dev/null || return 1
            ;;
        kv,2) ;;
        *)
            echo "❌ openbao_configure: secret/ is already mounted as '$mount', not KV v2. ESO's eso-read policy reads secret/data/*, which this mount cannot serve; move or remove it before re-running." >&2
            return 1
            ;;
    esac
    echo "   • Kubernetes auth"
    openbao_run_with_token 'bao auth list -format=json | grep -q "\"kubernetes/\"" || bao auth enable kubernetes >/dev/null' </dev/null || return 1
    openbao_run_with_token 'bao write auth/kubernetes/config kubernetes_host="https://${KUBERNETES_PORT_443_TCP_ADDR}:443" >/dev/null' </dev/null || return 1
    echo "   • eso-read policy and eso-role"
    openbao_run_with_token 'bao policy write eso-read - >/dev/null' <<'EOF' || return 1
path "secret/data/*" { capabilities = ["read"] }
EOF
    openbao_run_with_token 'bao write auth/kubernetes/role/eso-role bound_service_account_names=external-secrets bound_service_account_namespaces=external-secrets policies=eso-read ttl=1h >/dev/null' </dev/null || return 1
    echo "   • secret/demo canary"
    local canary
    canary=$(openbao_kv_path_state secret/demo) || return 1
    if [[ "$canary" == "absent" ]]; then
        openbao_run_with_token 'bao kv put secret/demo foo=bar >/dev/null' </dev/null || return 1
    fi
}

# Realm-declared seeds: one per line, `<kv-path> <key> [<key>...]`, blank or
# whitespace-only lines and `#` comments ignored. For each path that does not
# exist yet, generate a random 32-byte base64 value per key and write them in
# one put. Existing paths are never touched, so re-running is a no-op and a
# rotation is an explicit `bao kv put`, not a re-bootstrap. The realm names
# the paths; nordri never learns what they are for.
#
# Path and key names are interpolated into a shell snippet run inside the pod,
# so both are held to a strict allowlist before anything is built from them.
# openbao_seed_file <file>
openbao_seed_file() {
    local file="$1" line path keys key scratch jq_args
    [[ -r "$file" ]] || { echo "❌ openbao_seed_file: cannot read $file" >&2; return 1; }
    local lineno=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        line="${line%%#*}"
        line="${line//$'\r'/}"
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        # shellcheck disable=SC2206
        keys=($line)
        path="${keys[0]}"
        keys=("${keys[@]:1}")
        if [[ ${#keys[@]} -eq 0 ]]; then
            echo "❌ openbao_seed_file: $file:$lineno names path '$path' with no keys." >&2
            return 1
        fi
        if [[ ! "$path" =~ ^secret/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ || "$path" == *..* ]]; then
            echo "❌ openbao_seed_file: $file:$lineno path '$path' must be secret/<segments> of [A-Za-z0-9._-], no '..'." >&2
            return 1
        fi
        for key in "${keys[@]}"; do
            if [[ ! "$key" =~ ^[A-Za-z0-9._-]+$ ]]; then
                echo "❌ openbao_seed_file: $file:$lineno key '$key' must match [A-Za-z0-9._-]." >&2
                return 1
            fi
        done
        local state
        state=$(openbao_kv_path_state "$path") || return 1
        if [[ "$state" == "present" ]]; then
            echo "   ✅ $path present — leaving it alone."
            continue
        fi
        # Values rest only in 0600 files inside a 0700 scratch dir; jq reads
        # them by path (--rawfile) so no value ever enters an argument list.
        # They live in their own subdirectory so a key named `put.json` cannot
        # collide with the output file jq is about to truncate.
        scratch=$(openbao_scratch_dir) || return 1
        mkdir "$scratch/values" || { rm -rf "$scratch"; return 1; }
        jq_args=()
        for key in "${keys[@]}"; do
            openssl rand -base64 32 | tr -d '\r\n' > "$scratch/values/$key" || { rm -rf "$scratch"; return 1; }
            jq_args+=(--rawfile "$key" "$scratch/values/$key")
        done
        # Build {key: value, ...} from the named rawfiles: $ARGS.named holds
        # every --rawfile under its key name.
        if ! jq -n "${jq_args[@]}" '$ARGS.named' > "$scratch/put.json"; then
            rm -rf "$scratch"; return 1
        fi
        if ! openbao_run_with_token "bao kv put $path - >/dev/null" < "$scratch/put.json"; then
            rm -rf "$scratch"
            echo "❌ openbao_seed_file: writing $path failed." >&2
            return 1
        fi
        rm -rf "$scratch"
        echo "   🔑 $path seeded (${#keys[@]} generated value(s): ${keys[*]})."
    done < "$file"
}
