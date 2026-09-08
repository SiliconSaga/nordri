# components/nordri/lib/patch-urls.sh
# Target-specific repoURL rewrite for hydrated trees. Sourced by bootstrap.sh,
# update-embedded-git.sh and lib/hydrate.sh.
#
# Git carries the DURABLE form of every ArgoCD repoURL — the in-cluster Forgejo
# host — because after the Forgejo cutover Forgejo's main is GitHub's main
# verbatim, and a committed seed URL would be pulled straight back over the
# cutover. The seed Gitea only ever sees a hydrated copy, so the seed form is
# applied here, at hydration, the same way overlay paths and the GCP project
# are stamped. See realm-siliconsaga docs/plans/2026-09-07-forgejo-day2-design.md.
#
# Modes:
#   seed     rewrite Forgejo URLs -> seed URLs (bootstrap, day-2 seed hydration)
#   forgejo  leave the tree alone (hydration into Forgejo)
#   swap     leave the tree alone (the cutover commit pushed INTO the seed, which
#            must point ArgoCD at Forgejo — the only seed hydration without the
#            rewrite; distinct from `forgejo` so callers say what they mean)
#
# These two literals are the ONLY place either host lives in nordri's scripts.
FORGEJO_GIT_BASE_URL="http://forgejo-http.forgejo.svc.cluster.local:3000/siliconsaga"
SEED_GIT_BASE_URL="http://gitea-http.gitea.svc.cluster.local:3000/nordri-admin"

# patch_repo_urls_tree <tree> <mode>
# Echoes the number of files rewritten. Only *.yaml files are touched: docs
# and scripts that mention a host are prose, not manifests.
patch_repo_urls_tree() {
    local tree="$1" mode="$2"
    case "$mode" in
        seed) ;;
        forgejo|swap)
            echo 0
            return 0
            ;;
        *)
            echo "❌ patch_repo_urls_tree: unknown mode '$mode' (expected seed|forgejo|swap)." >&2
            return 1
            ;;
    esac
    local changed=0 f
    while IFS= read -r -d '' f; do
        grep -q "$FORGEJO_GIT_BASE_URL" "$f" || continue
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "s|$FORGEJO_GIT_BASE_URL|$SEED_GIT_BASE_URL|g" "$f" || return 1
        else
            sed -i "s|$FORGEJO_GIT_BASE_URL|$SEED_GIT_BASE_URL|g" "$f" || return 1
        fi
        # Fail closed, as patch-velero does: a Forgejo URL surviving into the
        # seed means ArgoCD would try a host that does not exist yet.
        if grep -q "$FORGEJO_GIT_BASE_URL" "$f"; then
            echo "❌ patch_repo_urls_tree: Forgejo URL survived rewrite in ${f#"$tree"/}." >&2
            return 1
        fi
        changed=$((changed + 1))
    done < <(find "$tree" -type f -name '*.yaml' -print0)
    echo "$changed"
}
