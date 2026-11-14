#!/usr/bin/env bash
# Unit test for lib/gitops.sh and the org-aware gitea_ensure_repo: org names,
# the stable address, the idempotent org and Service creation, the root
# Applications rendered with the stable URL and path cluster. curl and kubectl
# are recording stubs.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
. "$root/lib/gitea.sh"; . "$root/lib/gitops.sh"
fails=0
check() { if eval "$2"; then echo "ok - $1"; else echo "NOT OK - $1"; fails=$((fails+1)); fi; }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
LOG="$work/log"; : > "$LOG"; ARGV_LOG="$work/argv"; : > "$ARGV_LOG"; APPLIED="$work/applied"; : > "$APPLIED"

check "canonical org drops the realm- prefix" "[[ \$(gitops_canonical_org realm-siliconsaga) == siliconsaga ]]"
check "vendor org" "[[ \$(gitops_vendor_org realm-siliconsaga) == siliconsaga-vendor ]]"
check "stable repo url" "[[ \$(gitops_repo_url siliconsaga nordri) == http://git.gitops.svc.cluster.local:3000/siliconsaga/nordri.git ]]"

# curl stub: GET /orgs/<x> → 404 the first time, 200 after a POST; POST → 201.
# Prints the status like the real -w '%{http_code}' call does.
# State lives in files: the real call runs inside $(...), so a shell variable
# set by the stub would be lost with the subshell.
curl() {
    local method="GET" url="" a
    for a in "$@"; do case "$a" in -X) method=next ;; GET|POST|PATCH|DELETE) [[ $method == next ]] && method=$a ;; http*) url=$a ;; esac; done
    printf '%s %s\n' "$method" "$url" >> "$LOG"
    printf '%s\n' "$*" >> "$ARGV_LOG"
    case "$method $url" in
        "GET "*/api/v1/orgs/*) [[ -e "$work/org-${url##*/}" ]] && printf 200 || printf 404 ;;
        "POST "*/api/v1/orgs) : > "$work/org-siliconsaga"; : > "$work/org-siliconsaga-vendor"; printf 201 ;;
        "POST "*/api/v1/orgs/*/repos) printf 201 ;;
        *) printf 500 ;;
    esac
}
kubectl() {
    printf '%s\n' "$*" >> "$LOG"
    case "$*" in
        *"get service git -n gitops -o jsonpath={.spec.externalName}"*) printf '%s' "${GIT_TARGET:-}" ;;
        *"apply -f -"*) cat >> "$APPLIED" ;;
        *"apply -n argo -f "*) cat "${@: -1}" >> "$APPLIED" ;;
    esac
    return 0
}
GITEA_USER=nordri-admin GITEA_PASS='s3cr3t-p@ss"q' GITEA_HOST=localhost:3000 GITEA_SCHEME=http; gitea_build_urls

gitops_ensure_org siliconsaga >/dev/null; gitops_ensure_org siliconsaga >/dev/null
check "org created once, then found" "[[ \$(grep -c 'POST .*/api/v1/orgs$' \"\$LOG\") -eq 1 ]]"
gitea_ensure_repo siliconsaga nordri true >/dev/null
check "repo created under the org" "grep -q 'POST .*/api/v1/orgs/siliconsaga/repos' \"\$LOG\""
check "credentials reach curl via -K, never argv" "grep -q -- '-K' \"\$ARGV_LOG\" && ! grep -qF -- \"\$GITEA_PASS\" \"\$ARGV_LOG\""

GIT_TARGET="" gitops_ensure_git_service >/dev/null
check "Service git created pointing at the seed" "grep -q 'externalName: gitea-http.gitea.svc.cluster.local' \"\$APPLIED\""
: > "$APPLIED"; GIT_TARGET="forgejo-http.forgejo.svc.cluster.local" gitops_ensure_git_service >/dev/null
check "an existing target is left alone" "[[ ! -s \"\$APPLIED\" ]]"
: > "$APPLIED"; GIT_TARGET="gitea-http.gitea.svc.cluster.local" gitops_ensure_git_service forgejo-http.forgejo.svc.cluster.local >/dev/null
check "an explicit target repoints" "grep -q 'externalName: forgejo-http.forgejo.svc.cluster.local' \"\$APPLIED\""

: > "$APPLIED"; SCRIPT_DIR="$root" gitops_apply_root_apps realm-siliconsaga >/dev/null
check "nordri root uses the stable address" "grep -q 'repoURL: .http://git.gitops.svc.cluster.local:3000/siliconsaga/nordri.git' \"\$APPLIED\""
check "realm root uses the stable address" "grep -q 'repoURL: .http://git.gitops.svc.cluster.local:3000/siliconsaga/realm-siliconsaga.git' \"\$APPLIED\""
check "realm root path is cluster" "grep -q 'path: cluster' \"\$APPLIED\""
check "no placeholder survives" "! grep -q '__REALM_REPO__' \"\$APPLIED\""
check "no seed URL survives in the applied roots" "! grep -q 'gitea-http' \"\$APPLIED\""
echo "---"; [ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
