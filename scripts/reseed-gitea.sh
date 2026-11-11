#!/bin/bash
set -e

# Reinstall the seed Gitea on a running cluster, without the rest of bootstrap.
# Usage: scripts/reseed-gitea.sh [gke|homelab]
#
# For a seed whose Helm release is broken or in an older shape. A seed that only
# lost its repositories (the pod restarted; storage is ephemeral by design) does
# NOT need this: update-embedded-git.sh recreates the repos and re-hydrates.
#
# The install is gitea_install_seed from lib/gitea.sh, the same one bootstrap.sh
# runs, so a reseed comes up in exactly the bootstrap shape. If the existing
# release is too different for an in-place upgrade (the pre-2026-09 shape with
# Postgres/Valkey subcharts), `helm uninstall gitea -n gitea` first and delete
# its leftover PVCs; nothing in the seed survives a reinstall anyway.
#
# The admin password is kept, never generated: it comes from GITEA_PASS or the
# gitea/gitea-admin-credentials Secret, so update-embedded-git.sh keeps working.
# A cluster with neither needs bootstrap.sh, not this.
#
# Optional environment:
#   GITEA_CHART_VERSION  pin the chart version (default: latest)
#   KUBE_CONTEXT         the context this run is for; see lib/kube-context.sh
#
# Afterwards, re-hydrate: ./update-embedded-git.sh <target> <realm>

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$SCRIPT_DIR/lib/gitea.sh"
. "$SCRIPT_DIR/lib/kube-context.sh"
TARGET=$1

if [[ "$TARGET" != "gke" && "$TARGET" != "homelab" ]]; then
    echo "Usage: scripts/reseed-gitea.sh [gke|homelab]" >&2
    exit 1
fi

require_kube_context "$TARGET" || exit 1

GITEA_CREDENTIALS_NAMESPACE="gitea"
GITEA_CREDENTIALS_SECRET="gitea-admin-credentials"
GITEA_USER="nordri-admin"

if [[ -z "${GITEA_PASS:-}" ]]; then
    if kubectl get secret -n "$GITEA_CREDENTIALS_NAMESPACE" "$GITEA_CREDENTIALS_SECRET" >/dev/null 2>&1; then
        GITEA_PASS="$(kubectl get secret -n "$GITEA_CREDENTIALS_NAMESPACE" "$GITEA_CREDENTIALS_SECRET" -o jsonpath='{.data.password}' | base64 --decode)"
    fi
fi
if [[ -z "${GITEA_PASS:-}" ]]; then
    echo "❌ No $GITEA_CREDENTIALS_NAMESPACE/$GITEA_CREDENTIALS_SECRET Secret and no GITEA_PASS env var." >&2
    echo "   A reseed keeps the existing admin password. For a cluster that never had one, run bootstrap.sh." >&2
    exit 1
fi
echo "🔑 Using the existing Gitea admin password (user: $GITEA_USER)."

echo "📦 Reinstalling the seed Gitea..."
gitea_install_seed
echo "⏳ Waiting for Gitea to become ready..."
gitea_wait_ready 300 || exit 1

echo "✅ Seed Gitea reinstalled. Its repositories are empty until you re-hydrate:"
echo "   ./update-embedded-git.sh $TARGET <realm>"
