# components/nordri/lib/kube-context.sh
# Refuse to run a target against the wrong cluster. bootstrap.sh and
# update-embedded-git.sh call plain `kubectl`, which follows the kubeconfig's
# CURRENT context — not the `ws k8s` guard scope, which only wraps `ws k8s`
# itself and does not switch the context. On 2026-09-16 a gke rehydrate driven
# from a workstation whose current context was a local Docker Desktop cluster
# read that cluster's Gitea admin Secret and sent its password to the gke seed;
# the 401 stopped it before anything else ran, which is the only reason it was
# a nuisance and not an incident.
#
# Two checks, both before anything touches a cluster:
#   1. KUBE_CONTEXT, if set, must equal the current context. Setting it is the
#      explicit way to say which cluster a run is for; the mismatch message
#      names the fix rather than switching contexts behind the caller's back.
#   2. The current context's shape must fit the target: gke targets need a
#      GKE context (`gke_<project>_<zone>_<cluster>`, the form gcloud writes),
#      homelab targets must not use one. This catches the realistic mistake
#      even when KUBE_CONTEXT is unset.
# Sourced by both scripts. require_kube_context <gke|homelab>

require_kube_context() {
    local target="$1" current
    current=$(kubectl config current-context 2>/dev/null | tr -d '\r') || current=""
    if [[ -z "$current" ]]; then
        echo "❌ kubectl has no current context. Pick the cluster this $target run is for: kubectl config use-context <name>" >&2
        return 1
    fi
    if [[ -n "${KUBE_CONTEXT:-}" && "$KUBE_CONTEXT" != "$current" ]]; then
        echo "❌ KUBE_CONTEXT=$KUBE_CONTEXT but kubectl's current context is '$current'." >&2
        echo "   These scripts follow the current context, so switch first: kubectl config use-context $KUBE_CONTEXT" >&2
        return 1
    fi
    case "$target" in
        gke)
            if [[ "$current" != gke_* ]]; then
                echo "❌ Target is gke but the current kubectl context is '$current', which is not a GKE context (gke_<project>_<zone>_<cluster>)." >&2
                echo "   Switch to the GKE cluster first: kubectl config use-context gke_<project>_<zone>_<cluster>" >&2
                return 1
            fi
            ;;
        homelab)
            if [[ "$current" == gke_* ]]; then
                echo "❌ Target is homelab but the current kubectl context is '$current', a GKE cluster." >&2
                echo "   Switch to the homelab cluster first: kubectl config use-context <name>" >&2
                return 1
            fi
            ;;
        *)
            echo "❌ require_kube_context: unknown target '$target' (expected gke|homelab)." >&2
            return 1
            ;;
    esac
    echo "🎯 kubectl context: $current (target: $target)"
}
