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
