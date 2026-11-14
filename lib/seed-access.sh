# components/nordri/lib/seed-access.sh
# The Git-server credential resolution and reachability block shared by
# update-embedded-git.sh, scripts/migrate.sh (and graduate.sh): admin
# credentials from the cluster, URL bases, and a kubectl port-forward or probe.
# Needs lib/gitea.sh sourced first. The caller owns the EXIT trap (kill PF_PID,
# remove TEMP_DIRS).
#
# seed_access_open reads:
#   TARGET_SERVER  "seed" (default) or "forgejo"
#   GITEA_HOST     default localhost:3000 (port-forward); anything else is used as is
#   GITEA_PASS     optional explicit password, beats the Secret
#   GITEA_SCHEME   default http
# and sets GITEA_USER, GITEA_PASS, GITEA_HOST, GITEA_SCHEME, GITEA_API_URL,
# GITEA_GIT_BASE, GITEA_PROBE_URL and, when it starts one, PF_PID.
# Returns 1 (message on stderr) when it cannot reach a credential or the server.
seed_access_open() {
    local explicit_pass="${GITEA_PASS:-}" secret_pass="" attempts
    TARGET_SERVER="${TARGET_SERVER:-seed}"
    if [[ "$TARGET_SERVER" == "forgejo" ]]; then
        GITEA_CREDENTIALS_NAMESPACE="forgejo"
        GITEA_CREDENTIALS_SECRET="forgejo-admin"
        GITEA_PF_SERVICE="svc/forgejo-http"
        GITEA_PF_NAMESPACE="forgejo"
    else
        GITEA_CREDENTIALS_NAMESPACE="gitea"
        GITEA_CREDENTIALS_SECRET="gitea-admin-credentials"
        GITEA_PF_SERVICE="svc/gitea-http"
        GITEA_PF_NAMESPACE="gitea"
    fi
    if kubectl get secret -n "$GITEA_CREDENTIALS_NAMESPACE" "$GITEA_CREDENTIALS_SECRET" >/dev/null 2>&1; then
        secret_pass="$(kubectl get secret -n "$GITEA_CREDENTIALS_NAMESPACE" "$GITEA_CREDENTIALS_SECRET" -o jsonpath='{.data.password}' | base64 --decode)"
    fi

    if [[ "$TARGET_SERVER" == "forgejo" ]]; then
        GITEA_USER="$(kubectl get secret -n forgejo forgejo-admin -o jsonpath='{.data.username}' | base64 -d)"
        [[ -n "$GITEA_USER" ]] || { echo "❌ forgejo/forgejo-admin has no username." >&2; return 1; }
    else
        # Username is fixed (see bootstrap.sh header for rationale).
        GITEA_USER="nordri-admin"
    fi

    if [[ -n "$explicit_pass" ]]; then
        GITEA_PASS="$explicit_pass"
    elif [[ -n "$secret_pass" ]]; then
        GITEA_PASS="$secret_pass"
        echo "🔑 Loaded credentials from $GITEA_CREDENTIALS_NAMESPACE/$GITEA_CREDENTIALS_SECRET (user: $GITEA_USER)."
    else
        echo "❌ No $GITEA_CREDENTIALS_NAMESPACE/$GITEA_CREDENTIALS_SECRET Secret and no GITEA_PASS env var." >&2
        echo "   For a cluster bootstrapped before the Secret-backed flow landed:" >&2
        echo "     • One-shot:  GITEA_PASS=<live-pw> and re-run this script" >&2
        echo "     • Persist:   GITEA_PASS=<live-pw> bootstrap.sh <realm> <cluster>" >&2
        echo "   For a fresh cluster, run bootstrap.sh first." >&2
        return 1
    fi

    GITEA_HOST="${GITEA_HOST:-localhost:3000}"
    # Scheme defaults to http intentionally (see update-embedded-git.sh header).
    GITEA_SCHEME="${GITEA_SCHEME:-http}"
    # The kubectl port-forward target only speaks plain HTTP.
    if [[ "$GITEA_HOST" == "localhost:3000" && "$GITEA_SCHEME" != "http" ]]; then
        echo "⚠️  Ignoring GITEA_SCHEME=$GITEA_SCHEME with default localhost:3000 — the port-forwarded service is HTTP-only. Forcing http."
        GITEA_SCHEME="http"
    fi
    # Credentials are percent-encoded into the git URL base; API calls go through
    # a curl config file, never argv.
    gitea_build_urls || return 1

    # Probe /api/v1/version before sending credentials: `nc` only proves
    # *something* is on the port, we want to confirm it is Gitea/Forgejo.
    if [[ "$GITEA_HOST" == "localhost:3000" ]]; then
        if probe_gitea; then
            echo "   Reusing existing endpoint at $GITEA_HOST."
        else
            echo "   Starting Port Forward to $GITEA_PF_SERVICE ($GITEA_PF_NAMESPACE)..."
            kubectl port-forward "$GITEA_PF_SERVICE" -n "$GITEA_PF_NAMESPACE" 3000:3000 > /dev/null 2>&1 &
            PF_PID=$!
            attempts=0
            until probe_gitea; do
                attempts=$((attempts + 1))
                if [[ $attempts -ge 30 ]]; then
                    echo "❌ The server did not become reachable on $GITEA_HOST within 30s." >&2
                    return 1
                fi
                sleep 1
            done
        fi
    else
        echo "   Using GITEA_HOST=$GITEA_HOST (skipping port-forward)."
        if ! probe_gitea; then
            echo "❌ The server is not answering at $GITEA_PROBE_URL." >&2
            echo "   Verify the HTTPRoute is deployed and DNS resolves." >&2
            return 1
        fi
    fi
}
