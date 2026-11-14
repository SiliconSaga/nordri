#!/usr/bin/env bash
set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/../../lib/gitea.sh"

fails=0
check() { if eval "$2"; then echo "ok - $1"; else echo "NOT OK - $1"; fails=$((fails+1)); fi; }

# Stub the cluster tools: record helm's install args, swallow everything else.
HELM_ARGS=""
helm() { if [[ "$1" == "upgrade" ]]; then HELM_ARGS="$*"; fi; return 0; }
# Stubs are called by the lib, which shellcheck does not follow.
# shellcheck disable=SC2329
kubectl() { return 0; }

GITEA_USER='nordri-admin'; GITEA_PASS='pw'
unset GITEA_CHART_VERSION
gitea_install_seed
check "installs the gitea release" "[[ \"\$HELM_ARGS\" == 'upgrade --install gitea gitea-charts/gitea --namespace gitea '* ]]"
check "no volume" "[[ \"\$HELM_ARGS\" == *'persistence.enabled=false'* ]]"
check "sqlite, not the postgres default" "[[ \"\$HELM_ARGS\" == *'DB_TYPE=sqlite3'* ]]"
check "postgres-ha subchart off" "[[ \"\$HELM_ARGS\" == *'postgresql-ha.enabled=false'* ]]"
check "valkey-cluster subchart off" "[[ \"\$HELM_ARGS\" == *'valkey-cluster.enabled=false'* ]]"
check "admin user passed" "[[ \"\$HELM_ARGS\" == *'gitea.admin.username=nordri-admin'* ]]"
check "unpinned by default" "[[ \"\$HELM_ARGS\" != *'--version'* ]]"

GITEA_CHART_VERSION=12.7.0
gitea_install_seed
check "GITEA_CHART_VERSION pins the chart" "[[ \"\$HELM_ARGS\" == *'--version 12.7.0'* ]]"

# gitea_wait_ready: a stubbed clock that ticks once per call, so neither path
# spends real seconds and the timeout fires on a known iteration. The tick lives
# in a file because every `$(date +%s)` runs in a subshell, where a variable
# increment would be lost and the clock would stand still forever.
CLOCK=$(mktemp); echo 0 > "$CLOCK"
date() { local n; n=$(( $(cat "$CLOCK") + 1 )); echo "$n" > "$CLOCK"; echo "$n"; }
sleep() { :; }

# shellcheck disable=SC2329
kubectl() { [[ "$1" == "get" ]] && echo "True"; return 0; }
out=$(gitea_wait_ready 10 2>/dev/null); rc=$?
check "wait_ready returns 0 once the pod is Ready" "[[ $rc -eq 0 ]]"
check "wait_ready reports Ready" "[[ \"\$out\" == *'Gitea pod is Ready'* ]]"

kubectl() { return 0; }
err=$(gitea_wait_ready 3 2>&1 >/dev/null); rc=$?
check "wait_ready returns 1 on timeout" "[[ $rc -eq 1 ]]"
check "wait_ready says it timed out" "[[ \"\$err\" == *'Timeout waiting for Gitea'* ]]"

echo "---"; [ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
