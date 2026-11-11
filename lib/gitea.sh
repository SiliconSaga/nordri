# components/nordri/lib/gitea.sh
# Shared Gitea plumbing for bootstrap.sh and update-embedded-git.sh.
# Expects GITEA_SCHEME / GITEA_HOST / GITEA_USER / GITEA_PASS to be set by the
# caller (each script resolves credentials its own way) before gitea_build_urls.

# Percent-encode a string so credentials with special chars (@, :, /, #) can be
# embedded in a git URL without corrupting URL parsing.
urlencode() { jq -rn --arg s "$1" '$s|@uri'; }

# Build the Gitea URL bases from the resolved GITEA_* vars.
# Sets: GITEA_API_URL, GITEA_GIT_BASE, GITEA_PROBE_URL.
gitea_build_urls() {
    local user_enc pass_enc
    user_enc="$(urlencode "$GITEA_USER")"
    pass_enc="$(urlencode "$GITEA_PASS")"
    GITEA_API_URL="${GITEA_SCHEME}://${GITEA_HOST}"
    GITEA_GIT_BASE="${GITEA_SCHEME}://${user_enc}:${pass_enc}@${GITEA_HOST}"
    GITEA_PROBE_URL="${GITEA_API_URL}/api/v1/version"
}

# Install (or upgrade) the seed Gitea in the slim, ephemeral shape: SQLite,
# in-memory cache/session, level queue, no subcharts, no volume. bootstrap.sh
# carries the reasoning for every flag; this is the one place the flags live, so
# a reseed cannot drift from a bootstrap (the 08/09 seed wipes were drift).
# Expects GITEA_USER / GITEA_PASS. GITEA_CHART_VERSION pins the chart (default:
# latest, as bootstrap always has).
gitea_install_seed() {
    local version_args=()
    if [[ -n "${GITEA_CHART_VERSION:-}" ]]; then
        version_args=(--version "$GITEA_CHART_VERSION")
    fi
    helm repo add gitea-charts https://dl.gitea.io/charts/ >/dev/null 2>&1 || true
    helm repo update gitea-charts >/dev/null
    kubectl create namespace gitea --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    helm upgrade --install gitea gitea-charts/gitea \
      --namespace gitea \
      ${version_args[@]+"${version_args[@]}"} \
      --set-string gitea.admin.username="$GITEA_USER" \
      --set-string gitea.admin.password="$GITEA_PASS" \
      --set persistence.enabled=false \
      --set postgresql-ha.enabled=false \
      --set postgresql.enabled=false \
      --set valkey-cluster.enabled=false \
      --set valkey.enabled=false \
      --set gitea.config.database.DB_TYPE=sqlite3 \
      --set gitea.config.session.PROVIDER=memory \
      --set gitea.config.cache.ADAPTER=memory \
      --set gitea.config.queue.TYPE=level \
      --set containerSecurityContext.runAsUser=1000 \
      --set containerSecurityContext.runAsGroup=1000 \
      --set podSecurityContext.fsGroup=1000 \
      --set rootless=true
}

# Wait for the seed Gitea pod to report Ready. Returns non-zero on timeout.
# gitea_wait_ready [timeout_seconds]   (default 300)
gitea_wait_ready() {
    local timeout=${1:-300} start elapsed status
    start=$(date +%s)
    while true; do
        elapsed=$(( $(date +%s) - start ))
        if [ "$elapsed" -gt "$timeout" ]; then
            echo "❌ Timeout waiting for Gitea to start." >&2
            return 1
        fi
        status=$(kubectl get pods -n gitea -l app.kubernetes.io/name=gitea -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
        if [[ "$status" == "True" ]]; then
            echo "✅ Gitea pod is Ready."
            return 0
        fi
        echo "   ... waiting for Gitea pod to be Ready ($elapsed/${timeout}s)"
        kubectl logs -n gitea -l app.kubernetes.io/name=gitea --tail=1 2>/dev/null || true
        sleep 5
    done
}

# Probe the Gitea endpoint. Returns 0 if Gitea answers /api/v1/version, non-zero
# otherwise — confirms we're talking to actual Gitea, not just any listener on
# this host:port, before sending credentials.
probe_gitea() {
    curl -fsS --max-time 5 "$GITEA_PROBE_URL" >/dev/null 2>&1
}

# Ensure a Gitea repo exists (create if missing). Treats 201 (Created) and 409
# (already exists) as success; retries transport errors up to 5x with a short
# backoff, then prints the response body and fails.
#
# Second arg auto_init=true is for FRESH repos (bootstrap): it creates an initial
# commit on `main` and sets HEAD, which ArgoCD apps using `targetRevision: HEAD`
# require — without it a fresh repo has no resolvable HEAD. The later force-push
# overwrites that auto-init commit. Day-2 callers (update-embedded-git.sh) omit
# it: the repo already exists with a HEAD, so 409 is the normal outcome.
gitea_ensure_repo() {
    local repo_name=$1 auto_init=${2:-false}
    local max_retries=5
    local i status response_file body
    # Build the body with jq so a repo name containing quotes/backslashes can't
    # corrupt the JSON. auto_init ("true"/"false") is injected as a JSON boolean.
    body=$(jq -n --arg name "$repo_name" --argjson auto_init "$auto_init" \
        '{name: $name, private: false} + (if $auto_init then {auto_init: true, default_branch: "main"} else {} end)')
    for i in $(seq 1 $max_retries); do
        response_file=$(mktemp)
        # `-u user:pass` keeps credentials out of the URL so special chars in
        # $GITEA_PASS can't corrupt URL parsing.
        status=$(curl -sS -o "$response_file" -w "%{http_code}" \
            -u "$GITEA_USER:$GITEA_PASS" \
            -X POST "$GITEA_API_URL/api/v1/user/repos" \
            -H "Content-Type: application/json" \
            -d "$body") || true
        case "$status" in
            201|409)
                rm -f "$response_file"
                return 0
                ;;
        esac
        if [[ $i -lt $max_retries ]]; then
            echo "   Repo creation attempt $i/$max_retries for '$repo_name' returned HTTP $status; retrying in 5s..." >&2
            rm -f "$response_file"
            sleep 5
            continue
        fi
        echo "❌ Failed to create or confirm Gitea repo '$repo_name' after $max_retries attempts (HTTP $status):" >&2
        cat "$response_file" >&2
        echo >&2
        rm -f "$response_file"
        return 1
    done
}
