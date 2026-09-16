# components/nordri/lib/openbao.sh
# Bring a freshly deployed OpenBao from "pod Running" to "usable by the stack"
# without a human in the loop: init, unseal, the one-time mount/auth/policy
# configuration External Secrets depends on, and realm-declared seed values.
# Sourced by bootstrap.sh (Layer 5b). Every function returns non-zero on
# failure and never prints key material: init output goes from the pod
# straight into the parked Secret, and the root token and unseal shares travel
# to the pod over stdin, never in an argument list.
#
# Why this exists: a fresh homelab on 2026-09-15 came up with every layer
# green and Keycloak's realm import still could not run, because three steps
# were still hands — `bao operator init`, the KV/auth/policy setup from the
# realm plan (Task A1.5), and seeding secret/leidangr/oidc. Each was scripted
# on the spot; this is that script made durable, in the shape Layer 5 already
# uses for Garage and Velero.
#
# Custody: the init material is parked in the in-cluster `openbao-init` Secret,
# which is the homelab posture realm ADR 0002 accepts (anyone who can read
# Secrets in `openbao` owns the vault). On a live environment the shares belong
# in the operator's password manager FIRST, which is why bootstrap runs the
# init half on gke only when OPENBAO_AUTO_INIT=1 is set deliberately.

OPENBAO_NS="${OPENBAO_NS:-openbao}"
OPENBAO_POD="${OPENBAO_POD:-openbao-0}"
OPENBAO_INIT_SECRET="${OPENBAO_INIT_SECRET:-openbao-init}"

# Wait until the OpenBao pod exists and its phase is Running (Ready is not the
# bar: an uninitialized or sealed pod is Running and NotReady by design).
# openbao_wait_running <timeout-seconds>
openbao_wait_running() {
    local timeout="${1:-600}" start elapsed phase
    start=$(date +%s)
    while true; do
        phase=$(kubectl get pod -n "$OPENBAO_NS" "$OPENBAO_POD" -o jsonpath='{.status.phase}' 2>/dev/null) || phase=""
        [[ "$phase" == "Running" ]] && return 0
        elapsed=$(( $(date +%s) - start ))
        if (( elapsed > timeout )); then
            echo "⚠️  openbao_wait_running: $OPENBAO_POD not Running after ${timeout}s (phase: ${phase:-absent})." >&2
            return 1
        fi
        echo "   ... waiting for $OPENBAO_POD to be Running ($elapsed/${timeout}s)"
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

# Read the parked root token into a caller-provided variable name, never
# echoing it. openbao_root_token <varname>
openbao_root_token() {
    local __var="$1" tok
    tok=$(kubectl get secret -n "$OPENBAO_NS" "$OPENBAO_INIT_SECRET" -o jsonpath='{.data.root_token}' 2>/dev/null | base64 -d) || tok=""
    if [[ -z "$tok" ]]; then
        echo "❌ openbao_root_token: no root_token in Secret $OPENBAO_NS/$OPENBAO_INIT_SECRET." >&2
        return 1
    fi
    printf -v "$__var" '%s' "$tok"
}

# Run a shell snippet inside the pod with BAO_TOKEN set from the parked root
# token. The token is stdin line 1; the caller's own stdin follows it, so
# `bao policy write name -` and `bao kv put path -` read their bodies as usual.
# openbao_run_with_token <sh-snippet>   (stdin: payload for the snippet, if any)
openbao_run_with_token() {
    local snippet="$1" _tok
    openbao_root_token _tok || return 1
    {
        printf '%s\n' "$_tok"
        cat
    } | kubectl exec -i -n "$OPENBAO_NS" "$OPENBAO_POD" -- sh -c "IFS= read -r BAO_TOKEN; export BAO_TOKEN; $snippet"
}

# Initialize if needed and park the init material. A leftover openbao-init
# Secret next to an UNinitialized instance means the PVC was wiped (a reset
# homelab, the documented "lost the shares" recovery): the stale material is
# kept under a timestamped name rather than deleted, and a fresh init proceeds.
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
            | kubectl apply -f - >/dev/null
        kubectl delete secret -n "$OPENBAO_NS" "$OPENBAO_INIT_SECRET" >/dev/null
    fi
    echo "   🔐 Initializing OpenBao (3 shares, threshold 2); parking the material in Secret $OPENBAO_NS/$OPENBAO_INIT_SECRET..."
    local init_json root
    init_json=$(kubectl exec -n "$OPENBAO_NS" "$OPENBAO_POD" -- bao operator init -key-shares=3 -key-threshold=2 -format=json) || {
        echo "❌ openbao_ensure_initialized: bao operator init failed." >&2
        return 1
    }
    root=$(printf '%s' "$init_json" | jq -r '.root_token')
    kubectl create secret generic "$OPENBAO_INIT_SECRET" -n "$OPENBAO_NS" \
        --from-literal=init.json="$init_json" \
        --from-literal=root_token="$root" >/dev/null || return 1
    unset init_json root
    echo "   ✅ Initialized. With seal: auto the shares are recovery keys; with shamir they unseal (Layer 5b does that next)."
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
    local i share
    for i in 0 1; do
        share=$(kubectl get secret -n "$OPENBAO_NS" "$OPENBAO_INIT_SECRET" -o jsonpath='{.data.init\.json}' | base64 -d | jq -r ".unseal_keys_b64[$i]") || return 1
        printf '%s\n' "$share" | kubectl exec -i -n "$OPENBAO_NS" "$OPENBAO_POD" -- \
            sh -c 'IFS= read -r s; bao operator unseal "$s" >/dev/null' || return 1
    done
    unset share
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
# and the secret/demo canary. Idempotent: existing mounts and auth methods are
# left alone, policy and role are rewritten to the same content, the canary is
# seeded only when absent.
openbao_configure() {
    echo "   • KV v2 at secret/"
    openbao_run_with_token 'bao secrets list -format=json | grep -q "\"secret/\"" || bao secrets enable -version=2 -path=secret kv >/dev/null' </dev/null || return 1
    echo "   • Kubernetes auth"
    openbao_run_with_token 'bao auth list -format=json | grep -q "\"kubernetes/\"" || bao auth enable kubernetes >/dev/null' </dev/null || return 1
    openbao_run_with_token 'bao write auth/kubernetes/config kubernetes_host="https://${KUBERNETES_PORT_443_TCP_ADDR}:443" >/dev/null' </dev/null || return 1
    echo "   • eso-read policy and eso-role"
    openbao_run_with_token 'bao policy write eso-read - >/dev/null' <<'EOF' || return 1
path "secret/data/*" { capabilities = ["read"] }
EOF
    openbao_run_with_token 'bao write auth/kubernetes/role/eso-role bound_service_account_names=external-secrets bound_service_account_namespaces=external-secrets policies=eso-read ttl=1h >/dev/null' </dev/null || return 1
    echo "   • secret/demo canary"
    openbao_run_with_token 'bao kv metadata get secret/demo >/dev/null 2>&1 || bao kv put secret/demo foo=bar >/dev/null' </dev/null || return 1
}

# Realm-declared seeds: one per line, `<kv-path> <key> [<key>...]`, blank lines
# and `#` comments ignored. For each path that does not exist yet, generate a
# random 32-byte base64 value per key and write them in one put. Existing paths
# are never touched, so re-running is a no-op and a rotation is an explicit
# `bao kv put`, not a re-bootstrap. The realm names the paths; nordri never
# learns what they are for. openbao_seed_file <file>
openbao_seed_file() {
    local file="$1" line path keys key rc json
    [[ -r "$file" ]] || { echo "❌ openbao_seed_file: cannot read $file" >&2; return 1; }
    local lineno=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        line="${line%%#*}"
        line="${line//$'\r'/}"
        [[ -z "${line// /}" ]] && continue
        # shellcheck disable=SC2206
        keys=($line)
        path="${keys[0]}"
        keys=("${keys[@]:1}")
        if [[ ${#keys[@]} -eq 0 ]]; then
            echo "❌ openbao_seed_file: $file:$lineno names path '$path' with no keys." >&2
            return 1
        fi
        if [[ "$path" != secret/* || "$path" == *..* ]]; then
            echo "❌ openbao_seed_file: $file:$lineno path '$path' must start with secret/ and contain no '..'." >&2
            return 1
        fi
        rc=0
        openbao_run_with_token "bao kv metadata get '$path' >/dev/null 2>&1" </dev/null || rc=$?
        case "$rc" in
            0) echo "   ✅ $path present — leaving it alone."; continue ;;
            2) ;;
            *) echo "❌ openbao_seed_file: could not check $path (exit $rc)." >&2; return 1 ;;
        esac
        json='{}'
        for key in "${keys[@]}"; do
            json=$(printf '%s' "$json" | jq --arg k "$key" --arg v "$(openssl rand -base64 32 | tr -d '\r\n')" '. + {($k): $v}')
        done
        printf '%s\n' "$json" | openbao_run_with_token "bao kv put '$path' - >/dev/null" || {
            echo "❌ openbao_seed_file: writing $path failed." >&2
            return 1
        }
        unset json
        echo "   🔑 $path seeded (${#keys[@]} generated value(s): ${keys[*]})."
    done < "$file"
}
