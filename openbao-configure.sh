#!/bin/bash
# nordri/openbao-configure.sh — the configure and seed halves of bootstrap's
# Layer 5b, standalone, for a cluster that is already running.
#
# Usage:
#   ./openbao-configure.sh <gke|homelab> [realm]
#
# Requires an initialized, unsealed OpenBao and the parked root token in
# Secret openbao/openbao-init (./openbao-init.sh or bootstrap Layer 5b put it
# there). Then, idempotently (lib/openbao.sh):
#   • KV v2 at secret/, Kubernetes auth, the eso-read policy and eso-role,
#     the openbao-backup policy and role for the chart's snapshot agent,
#     and the secret/demo canary
#   • the realm's openbao-seeds paths (<REALM_DIR>/openbao-seeds, or
#     OPENBAO_SEEDS_FILE), each written once if absent, never touched again
#
# Re-running on a configured cluster changes nothing, which makes this the
# way to add a policy or a seed path after the fact without a re-bootstrap.
#
# Environment: OPENBAO_NS, OPENBAO_POD, OPENBAO_INIT_SECRET, OPENBAO_SEEDS_FILE,
# REALM_DIR (default ../../realms/<realm> relative to this repo), KUBE_CONTEXT.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/openbao.sh"
. "$SCRIPT_DIR/lib/kube-context.sh"

TARGET="${1:-}"
REALM="${2:-}"

if [[ "$TARGET" != "gke" && "$TARGET" != "homelab" ]]; then
    echo "❌ Target must be 'gke' or 'homelab'." >&2
    echo "Usage: ./openbao-configure.sh <gke|homelab> [realm]" >&2
    exit 1
fi

# Same realm resolution as bootstrap.sh, minus the cluster/ requirement:
# only the seeds file matters here.
REALM_DIR="${REALM_DIR:-}"
if [[ -n "$REALM" ]]; then
    if [[ ! "$REALM" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || [[ ${#REALM} -gt 63 ]]; then
        echo "❌ Realm '$REALM' must be a DNS-1123 label (lowercase alphanumeric and '-', max 63 chars)." >&2
        exit 1
    fi
    if [[ -z "$REALM_DIR" ]]; then
        REALM_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")/realms/$REALM"
    fi
    if [[ ! -d "$REALM_DIR" ]]; then
        echo "❌ Realm '$REALM' not found at $REALM_DIR (set REALM_DIR to its checkout)." >&2
        exit 1
    fi
fi
OPENBAO_SEEDS_FILE="${OPENBAO_SEEDS_FILE:-}"
if [[ -z "$OPENBAO_SEEDS_FILE" && -n "$REALM" && -f "$REALM_DIR/openbao-seeds" ]]; then
    OPENBAO_SEEDS_FILE="$REALM_DIR/openbao-seeds"
fi

require_kube_context "$TARGET" || exit 1

echo "⏳ Waiting for $OPENBAO_NS/$OPENBAO_POD to answer bao status..."
openbao_wait_running 600 || exit 1

if [[ "$(openbao_status_field '.initialized')" != "true" || "$(openbao_status_field '.sealed')" != "false" ]]; then
    echo "❌ OpenBao on $TARGET is not initialized and unsealed. Run ./openbao-init.sh $TARGET <file> first (or bootstrap.sh, which does both on homelab)." >&2
    exit 1
fi
if ! kubectl get secret -n "$OPENBAO_NS" "$OPENBAO_INIT_SECRET" >/dev/null 2>&1; then
    echo "❌ Secret $OPENBAO_NS/$OPENBAO_INIT_SECRET is missing, so there is no root token to configure with." >&2
    echo "   Park it as nidavellir docs/secrets-management.md describes (init.json plus a root_token key), then re-run." >&2
    exit 1
fi

echo "🔧 Configuring OpenBao on $TARGET..."
openbao_configure || { echo "❌ OpenBao configuration failed." >&2; exit 1; }

if [[ -n "$OPENBAO_SEEDS_FILE" ]]; then
    echo "🌱 Seeding realm-declared OpenBao paths from $OPENBAO_SEEDS_FILE..."
    openbao_seed_file "$OPENBAO_SEEDS_FILE" || { echo "❌ OpenBao seeding failed." >&2; exit 1; }
else
    echo "ℹ️  No openbao-seeds file — nothing to seed."
fi
echo "✅ OpenBao ready: ESO can read secret/*, the snapshot agent can read the Raft snapshot, realm seeds present."
