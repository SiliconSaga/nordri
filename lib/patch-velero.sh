# components/nordri/lib/patch-velero.sh
# Stamp the GCP project into a hydrated nordri tree's Velero Application.
# Sourced by bootstrap.sh AND update-embedded-git.sh. Returns non-zero on any
# failure (caller decides whether to exit).
#
# Why this is a shared function rather than an inline block: the two scripts
# duplicate their hydration steps, and the first version of this lived only in
# bootstrap.sh. update-embedded-git.sh — the DAY-2 path, the one actually used
# to push a config change — would then have pushed `velero-gke.yaml` with the
# literal `__GCP_PROJECT__` still in it, producing a Velero pointed at a bucket
# named `__GCP_PROJECT__-velero` and annotated with a service account that
# cannot exist. It would have come up, reported healthy, and stored nothing:
# precisely the failure the Velero split was written to fix, reintroduced by
# the update path. Anything target-specific belongs in a lib both callers
# source, not in whichever script happened to need it first.
#
# No-op for homelab, which uses velero-homelab.yaml and has no project to stamp.
patch_velero_tree() {
    local tree="$1" target="$2"
    local app="$tree/platform/fundamentals/apps/velero-gke.yaml"

    case "$target" in
        homelab)
            return 0
            ;;
        gke) ;;
        *)
            echo "❌ patch_velero_tree: unknown target '$target' (expected homelab|gke)." >&2
            return 1
            ;;
    esac

    if [[ ! -f "$app" ]]; then
        echo "❌ patch_velero_tree: expected $app to exist for GKE hydration." >&2
        return 1
    fi

    # Env var wins; otherwise fall back to gcloud's configured project so an
    # operator who has already run `gcloud config set project` needs no export.
    local project="${GCP_PROJECT:-}"
    if [[ -z "$project" ]] && command -v gcloud >/dev/null 2>&1; then
        project="$(gcloud config get-value project 2>/dev/null || true)"
    fi
    if [[ -z "$project" || "$project" == "(unset)" ]]; then
        echo "❌ GCP_PROJECT is not set and gcloud has no default project." >&2
        echo "   Velero on GKE needs it for the GCS bucket name and the Workload" >&2
        echo "   Identity service-account annotation." >&2
        echo "     export GCP_PROJECT=<your-project-id>" >&2
        echo "   or: gcloud config set project <your-project-id>" >&2
        return 1
    fi

    # Reject anything that is not a plausible GCP project id before it reaches
    # sed. A value containing `|` would break the expression; one containing a
    # space or slash would produce a manifest that renders but is nonsense.
    if [[ ! "$project" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]; then
        echo "❌ GCP_PROJECT '$project' is not a valid project id." >&2
        echo "   Expected 6-30 chars: lowercase letter, then letters/digits/hyphens." >&2
        return 1
    fi

    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s|__GCP_PROJECT__|$project|g" "$app" || return 1
    else
        sed -i "s|__GCP_PROJECT__|$project|g" "$app" || return 1
    fi

    # Fail closed. A surviving placeholder is worse than a hard error here,
    # because the resulting Velero looks installed and healthy.
    if grep -q '__GCP_PROJECT__' "$app"; then
        echo "❌ patch_velero_tree: placeholders survived substitution in $app." >&2
        return 1
    fi

    echo "   Velero GKE Application pinned to project: $project"
}
