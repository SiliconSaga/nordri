# components/nordri/lib/patch-mimir.sh
# Per-target patching of a hydrated mimir tree. Sourced by bootstrap.sh and
# update-embedded-git.sh. Returns non-zero on any failure (caller decides
# whether to exit).
#
# One cluster-specific rewrite: point the shared-data-clusters app at the realm
# overlay. The committed manifests under shared/ are realm-NEUTRAL — one local
# pgBackRest repo, no MySQL object storage, no cloud identity — and
# shared/overlays/gke is what adds the GCS repo, the Workload Identity
# annotation and the MySQL bucket on top.
#
# ⚠ WHY THIS PATCH EXISTS AT ALL. Until 2026-11-03 mimir had no per-target
# patching and the app pointed at a single flat `shared/`, so every realm was
# handed the GKE-shaped manifests verbatim. On homelab that meant pgBackRest
# authenticating to GCS through a metadata server that does not exist off GKE:
# it retried for 33 days, and because Postgres may not recycle a WAL segment
# until EVERY configured repo accepts it, an 85MB database accumulated 96.5GB of
# pg_wal and came within about a day of filling the host disk.
#
# The failure directions are NOT symmetric, which is why the verification below
# is a hard error rather than a warning:
#
#   patch does not run on homelab  → the realm gets a repo it cannot reach, and
#                                    silently refills the disk. The old bug.
#   patch does not run on gke      → the realm silently LOSES its offsite repo
#                                    and all MySQL backups, while every cluster
#                                    stays green. The worse of the two, because
#                                    nothing looks wrong until a restore.
#
# `sed` exits 0 when nothing matched, so an unverified substitution would
# produce exactly the second case.
patch_mimir_tree() {
    local tree="$1" target="$2"
    local shared_app="$tree/argocd/apps/shared-clusters.yaml"
    local overlay
    # Validate the caller-supplied target before any sed: an empty or unknown
    # target would rewrite the path to `shared/overlays/<bad>`, which ArgoCD
    # reports as a path-not-found on an app whose syncPolicy has prune disabled —
    # so the previous resources keep running and the breakage is quiet.
    case "$target" in
        homelab|gke) ;;
        *)
            echo "❌ patch_mimir_tree: unknown target '$target' (expected homelab|gke)." >&2
            return 1
            ;;
    esac
    if [[ ! -f "$shared_app" ]]; then
        echo "❌ Expected mimir manifest missing: ${shared_app#"$tree"/} — has argocd/apps/ been renamed?" >&2
        return 1
    fi
    overlay="shared/overlays/$target"
    # Guard the overlay the app is about to be pointed at. A target whose overlay
    # was never written would otherwise push a dangling path.
    if [[ ! -f "$tree/shared/overlays/$target/kustomization.yaml" ]]; then
        echo "❌ mimir overlay missing: shared/overlays/$target/kustomization.yaml" >&2
        return 1
    fi
    # Portable sed -i (BSD/macOS needs '' as the backup extension, GNU/MSYS must not).
    # Anchored to the line start so a 'path:' appearing in prose cannot match.
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s|^\( *\)path: shared$|\1path: $overlay|g" "$shared_app"
    else
        sed -i "s|^\( *\)path: shared$|\1path: $overlay|g" "$shared_app"
    fi
    # Anchored to the WHOLE line, not a substring. `grep -q "path: $overlay"`
    # would accept `path: shared/overlays/gke-old` as a successful patch for
    # target gke — a value the sed above does not touch, because it only matches
    # the bare `path: shared`. The function would then return 0 on a manifest it
    # never changed, which is the exact silent success this guard exists to deny.
    if ! grep -q "^ *path: $overlay$" "$shared_app"; then
        echo "❌ mimir shared-clusters overlay path not patched — the 'path: shared' placeholder may have changed." >&2
        return 1
    fi
}
