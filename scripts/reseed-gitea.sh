#!/bin/bash
set -eo pipefail

# Reinstall the seed Gitea on a running cluster, without the rest of bootstrap.
# Usage: scripts/reseed-gitea.sh <realm> <cluster>
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
# Not on a cluster the pre-Phase-3 code bootstrapped (its root Application still
# reads the old nordri-admin repositories): a reseed wipes those repositories,
# update-embedded-git.sh then refuses (that cluster has no identity), and
# bootstrap.sh refuses it too, so scripts/migrate.sh is the only way forward
# from there. Migrate such a cluster first; reseed after, if it still needs it.
#
# Optional environment:
#   GITEA_CHART_VERSION  pin the chart version (default: latest)
#   KUBE_CONTEXT         the context this run is for; see lib/kube-context.sh
#
# Afterwards, re-hydrate: ./update-embedded-git.sh <realm>

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$SCRIPT_DIR/lib/gitea.sh"
. "$SCRIPT_DIR/lib/identity.sh"
. "$SCRIPT_DIR/lib/kube-context.sh"
REALM="${1:-}"; CLUSTER="${2:-}"

if [[ -z "$REALM" || -z "$CLUSTER" ]]; then
    echo "Usage: scripts/reseed-gitea.sh <realm> <cluster>" >&2
    exit 1
fi
for v in "$REALM" "$CLUSTER"; do
    if [[ ! "$v" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || [[ ${#v} -gt 63 ]]; then
        echo "❌ '$v' must be a DNS-1123 label (lowercase alphanumeric and '-', max 63 chars)." >&2; exit 1
    fi
done
REALM_DIR="${REALM_DIR:-$(dirname "$(dirname "$SCRIPT_DIR")")/realms/$REALM}"
if [[ ! -d "$REALM_DIR/cluster" ]]; then
    echo "❌ Realm '$REALM' has no cluster/ config at: $REALM_DIR/cluster (set REALM_DIR or clone the realm)." >&2
    exit 1
fi
# The environment comes from the resolved identity, not the live cluster: the
# seed being reinstalled may be the only thing left to ask.
IDENTITY="$(identity_resolve "$REALM_DIR" "$CLUSTER")" || exit 1
TARGET="$(printf '%s\n' "$IDENTITY" | sed -n 's/^environment=//p')"

require_kube_context "$TARGET" || exit 1
# The current context must be the named cluster: refuse when its live identity
# says otherwise (a cluster with no identity yet is let through).
LIVE_CLUSTER="$(identity_live_value cluster)"
if [[ -n "$LIVE_CLUSTER" && "$LIVE_CLUSTER" != "$CLUSTER" ]]; then
    echo "❌ The current kube context is cluster '$LIVE_CLUSTER', not '$CLUSTER'. Switch context first; this script never does." >&2
    exit 1
fi

GITEA_CREDENTIALS_NAMESPACE="gitea"
GITEA_CREDENTIALS_SECRET="gitea-admin-credentials"
GITEA_USER="nordri-admin"

# An env override is used as given and NOT written to the Secret (rotation is
# bootstrap.sh's job), so the re-hydrate has to be told the same password.
GITEA_PASS_FROM_ENV=0
if [[ -n "${GITEA_PASS:-}" ]]; then
    GITEA_PASS_FROM_ENV=1
else
    if ! kubectl get secret -n "$GITEA_CREDENTIALS_NAMESPACE" "$GITEA_CREDENTIALS_SECRET" >/dev/null 2>&1; then
        echo "❌ No $GITEA_CREDENTIALS_NAMESPACE/$GITEA_CREDENTIALS_SECRET Secret and no GITEA_PASS env var." >&2
        echo "   A reseed keeps the existing admin password. For a cluster that never had one, run bootstrap.sh." >&2
        exit 1
    fi
    if ! GITEA_PASS="$(kubectl get secret -n "$GITEA_CREDENTIALS_NAMESPACE" "$GITEA_CREDENTIALS_SECRET" -o jsonpath='{.data.password}' | base64 --decode)"; then
        echo "❌ Could not read the password from $GITEA_CREDENTIALS_NAMESPACE/$GITEA_CREDENTIALS_SECRET." >&2
        exit 1
    fi
    if [[ -z "$GITEA_PASS" ]]; then
        echo "❌ $GITEA_CREDENTIALS_NAMESPACE/$GITEA_CREDENTIALS_SECRET exists but its 'password' key is empty." >&2
        echo "   Set GITEA_PASS explicitly, or run bootstrap.sh to recreate the Secret." >&2
        exit 1
    fi
fi
echo "🔑 Using the existing Gitea admin password (user: $GITEA_USER)."

echo "📦 Reinstalling the seed Gitea..."
gitea_install_seed
echo "⏳ Waiting for Gitea to become ready..."
gitea_wait_ready 300 || exit 1

echo "✅ Seed Gitea reinstalled. Its repositories are empty until you re-hydrate:"
if [[ "$GITEA_PASS_FROM_ENV" -eq 1 ]]; then
    echo "   ./update-embedded-git.sh $REALM   — with GITEA_PASS exported to the same value, as for this run"
    echo "   The $GITEA_CREDENTIALS_NAMESPACE/$GITEA_CREDENTIALS_SECRET Secret was not updated, so without GITEA_PASS the hydrate would read a password this Gitea no longer accepts."
    echo "   Set it without echo ('read -rs GITEA_PASS; export GITEA_PASS'), not inline on the command line, where shell history keeps it."
else
    echo "   ./update-embedded-git.sh $REALM"
fi
