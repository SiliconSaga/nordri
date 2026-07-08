#!/usr/bin/env bash
set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/../../lib/gitea.sh"

fails=0
check() { if eval "$2"; then echo "ok - $1"; else echo "NOT OK - $1"; fails=$((fails+1)); fi; }

GITEA_SCHEME=http; GITEA_HOST=localhost:3000; GITEA_USER='nordri-admin'; GITEA_PASS='p@ss:/w#rd'
gitea_build_urls
check "api url built" "[ \"\$GITEA_API_URL\" = 'http://localhost:3000' ]"
check "probe url built" "[ \"\$GITEA_PROBE_URL\" = 'http://localhost:3000/api/v1/version' ]"
check "git base percent-encodes creds" "printf '%s' \"\$GITEA_GIT_BASE\" | grep -q 'nordri-admin:p%40ss%3A%2Fw%23rd@localhost:3000'"

echo "---"; [ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
