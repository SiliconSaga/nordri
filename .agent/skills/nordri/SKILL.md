---
name: nordri
description: Use when bootstrapping Nordri on a fresh cluster, debugging the numbered-layer install order (L2 → L5), looking up pinned versions of Crossplane / providers / functions / Traefik, configuring the Garage S3 init or Velero credentials seam, or understanding the seed-Gitea-internal-URL pattern ArgoCD syncs from. Defers up to `argocd-gitops` and `crossplane-compositions` (sibling skills) for generic platform-API + GitOps operational depth; this skill is the Nordri-specific Layer/version/Garage index.
---

# nordri

## Overview

Nordri's bootstrap is a numbered-layer sequence in `bootstrap.sh` — pre-ArgoCD layers install via raw Helm/kubectl, then ArgoCD adopts the running Helm releases and takes over via app-of-apps. The layer order solves the CRD-chicken-and-egg problem (Gateway API + Crossplane providers must exist before ArgoCD tries to sync resources that reference them). This skill indexes the layer map, the pinned-version locations, and the Garage/GKE split so you don't have to reverse-engineer it from `bootstrap.sh`.

## When to Use

- Fresh-cluster bootstrap on homelab (Rancher Desktop) or GKE.
- "Why is X installed via Helm directly and not ArgoCD?" (answer: it's a pre-Layer-3 CRD provider).
- Looking up the pinned Crossplane / provider / function version for a Composition you're authoring.
- Debugging Garage init (homelab) or Velero credentials Secret missing (GKE).
- Understanding why ArgoCD lives in namespace `argo` (not `argocd`) and how seed-Gitea fits.

NOT for the generic ArgoCD GitOps patterns — sibling skill `argocd-gitops` covers test-through-Git, app-of-apps prune cascade, SSA for large CRDs, etc. NOT for Crossplane Composition Pipeline-mode patterns — sibling skill `crossplane-compositions` covers `crossplane render`, CEL readiness, CompositionRevision flapping. NOT for Mimir data-service operator wiring (Percona crVersion, Strimzi, etc.) — that's Mimir-component-skill territory.

## Quick Reference

| Need to know | Where it lives | Why |
|---|---|---|
| Layer ordering | `bootstrap.sh` (thorough inline comments) | Source of truth — the comments explain *why* each layer exists |
| Crossplane core version | `bootstrap.sh` (Helm flag `--version 2.1.4` on the Crossplane install) | Bumped together with the providers |
| Provider + function versions | `platform/fundamentals/manifests/crossplane-providers.yaml` | Single YAML, one entry per provider/function |
| Traefik chart version | `bootstrap.sh` (chart 38.0.1, pinned via Helm `--version`) | Chart 38+ bundles Gateway API CRDs as part of the install; earlier setups applied Gateway API CRDs separately, which caused a field-manager conflict on first Helm install |
| Garage init flow | `bootstrap.sh` Layer 5 (homelab only) | Waits for `garage/garage-0` Ready, then `layout assign -z dc1 -c 1G` per node → `layout apply --version 1` → create key → create bucket → write `velero/velero-credentials` Secret |
| GKE Velero credentials | Pre-created placeholder Secret to avoid CrashLoopBackOff | TODO: replace with GCS + Workload Identity (see `docs/velero-gke.md`) |
| ArgoCD namespace | `argo` (NOT `argocd`) | Reserved to avoid colliding with legacy installations |
| Seed Gitea internal URL | `http://gitea-http.gitea.svc.cluster.local:3000` | ArgoCD Applications target this during bootstrap; can be switched to GitHub later |
| Admin creds | Secret `gitea/gitea-admin-credentials`, user `nordri-admin` | Password sourced from `$GITEA_PASS` env (or an existing `gitea-admin-credentials` Secret), passed to Helm via `--set-string gitea.admin.password="$GITEA_PASS"`, and re-written into the Secret. |

## Bootstrap Layer Map

```text
bootstrap.sh [gke|homelab]
  L2    Seed Gitea (Helm, persistence=false, bundled Postgres+Valkey)
        + hydrate nordri/nidavellir/mimir/heimdall via port-forward + git push --force
  L2.5  Crossplane Core (Helm)
  L2.6  Traefik (Helm 38.0.1 — bundles Gateway API CRDs + IngressRoute/Middleware CRDs)
  L2.7  Crossplane Providers + Functions (kubectl apply crossplane-providers.yaml + wait Healthy)
  L2.8  Crossplane ProviderConfigs + RBAC (crossplane-configs.yaml)
  L3    ArgoCD (Helm, dex.enabled=false, server.insecure=true,
                kustomize buildOptions: --enable-helm, LoadRestrictionsNone)
  L4    Apply platform/root-app.yaml — ArgoCD adopts pre-installed Helm releases
        (same release name/namespace → seamless takeover) and takes over from here
  L5    (homelab only) Wait garage/garage-0 Ready, run layout assign + apply,
        create velero-service-key + velero-backups bucket, write velero-credentials Secret
```

Why pre-ArgoCD layers exist: ArgoCD can't sync resources whose CRDs don't exist yet. Traefik (L2.6) registers `IngressRoute`/`Middleware`/Gateway-API CRDs before ArgoCD goes live. Crossplane providers (L2.7) register `ProviderConfig` CRDs before L2.8 can apply ProviderConfigs. Without this ordering, you'd get reams of "no matches for kind" errors at L3 sync.

## Pinned Versions (verify against `bootstrap.sh` + `crossplane-providers.yaml`)

| Component | Version | Notes |
|---|---|---|
| Crossplane Core | `2.1.4` | Pinned via Helm `--version 2.1.4` in `bootstrap.sh` (no `CROSSPLANE_VERSION` variable; the literal is inline on the install line) |
| Traefik chart | `38.0.1` (app `3.6.5`) | Chart 38.x bundles Gateway API CRDs (avoids the field-manager conflict a separate CRD apply used to cause). Don't bump Traefik **app** to `3.7.x` (any chart bump that pulls it in): there's a Gateway-provider cert regression on 3.7.x — stay on app `3.6.5` / chart `38.x` until that's fixed upstream. |
| provider-kubernetes | `v1.2.0` | `crossplane-providers.yaml` |
| provider-helm | `v1.0.0` | `crossplane-providers.yaml` |
| function-go-templating | `v0.4.0` | `crossplane-providers.yaml` |
| function-auto-ready | `v0.2.1` | `crossplane-providers.yaml` |
| function-environment-configs | `v0.4.0` | Required for Crossplane v2 (`spec.environment` removed from Composition; the `cluster-identity` pattern depends on this) |
| Gitea, ArgoCD chart | not pinned in `bootstrap.sh` | Latest from repo; bump deliberately if needed |

The pinned set is interdependent — bump Crossplane core and the function versions together as a unit; provider versions can lag slightly but verify the operator-image-vs-chart-version match for any data-services operators downstream (Mimir territory).

## Garage S3 + Velero Credentials (Homelab vs GKE)

**Homelab (Layer 5 actively does this):**

1. Wait up to 600s for `garage/garage-0` Ready (Garage is deployed by ArgoCD as a Tier-1 Application; bootstrap.sh just initializes it).
2. `garage status` → parse node IDs.
3. `garage layout assign -z dc1 -c 1G` per node (datacenter zone + capacity).
4. `garage layout apply --version 1`.
5. `garage key create velero-service-key` → parse Key ID + Secret.
6. `garage bucket create velero-backups` + `garage bucket allow --read --write velero-backups --key velero-service-key`.
7. Write `velero/velero-credentials` Secret with the AWS-style `[default]\naws_access_key_id=…\naws_secret_access_key=…` payload Velero expects.

**GKE (no Garage):**

A pre-created **placeholder** `velero-credentials` Secret prevents the Velero pod from CrashLoopBackOff while ArgoCD syncs it (Velero requires a credentials Secret to start, even if the backend isn't ready). The placeholder is a TODO: replace with **GCS as Velero target + Workload Identity** for keyless auth — see `docs/velero-gke.md`. Until that lands, GKE Velero is non-functional but the cluster bootstraps clean.

## Seed Gitea + ArgoCD Sync

ArgoCD Applications during bootstrap target `http://gitea-http.gitea.svc.cluster.local:3000/<owner>/<repo>` — the in-cluster Gitea. This is what `update-embedded-git.sh <homelab|gke>` hydrates from your local working tree.

The Gitea instance is **ephemeral by design** (bundled Postgres + Valkey from the Gitea chart, `persistence.enabled=false`). It exists to break the chicken-and-egg of "ArgoCD needs to sync from a Git source, but GitHub can't reach the cluster's API server during bootstrap." Day-2 plan to graduate this to a persistent Forgejo deployment lives in the realm (see `realms/realm-siliconsaga/docs/plans/`).

When GitHub is reachable from the cluster (i.e. post-bootstrap, on GKE), Applications can be re-pointed at GitHub directly — see the `nidavellir/vegvisir/README.md` transition notes (cross-repo; in the workspace checkout it lives at `components/nidavellir/vegvisir/README.md`).

## Common Mistakes

- **Skipping pre-ArgoCD Helm layers** ("can't ArgoCD just install Traefik?") — no. ArgoCD can't sync `IngressRoute` resources before the Traefik CRDs exist; Layer 2.6 is the resolution.
- **Bumping Traefik chart blindly** — chart 38+ owns the Gateway API CRDs; pre-38 setups that applied Gateway API CRDs separately caused a field-manager conflict on the first Helm install. Also: any chart bump that pulls Traefik **app** version `3.7.x` reintroduces a Gateway-provider cert regression we hit once. Stay on chart `38.x` / app `3.6.5` until that's resolved upstream.
- **Using `--set watchNamespace=""`** on any Helm-installed operator — Helm silently ignores empty strings. Use `watchAllNamespaces=true`. (Also covered in sibling `crossplane-compositions` skill.)
- **Garage init failing on `replicationFactor > node count`** — the homelab is single-node, the layout is 1/1. Multi-node homelab would need the Garage chart's `replicationFactor` adjusted via values overrides; see the Garage chart docs for the live key.
- **Git Bash MSYS path mangling** — `kubectl exec pod -- /garage <cmd>` from Git Bash converts `/garage` to `C:/Program Files/Git/garage`. Prefix with `MSYS_NO_PATHCONV=1` or run from PowerShell.

## Sources

- `bootstrap.sh` — single source of truth for the layer sequence and the Garage init flow. Read this first.
- `platform/fundamentals/manifests/crossplane-providers.yaml` — provider + function version pins.
- `platform/root-app.yaml` — the L4 entry point ArgoCD adopts.
- `docs/velero-gke.md` — Velero on GKE TODO (Workload Identity + GCS).
- Sibling skills: [`argocd-gitops`](../argocd-gitops/SKILL.md) for GitOps generic patterns; [`crossplane-compositions`](../crossplane-compositions/SKILL.md) for Composition Pipeline-mode patterns.
- Cross-repo (yggdrasil workspace): `realms/realm-siliconsaga/docs/stack-tier-1.md` carries the narrative; the Forgejo day-2 plan and other realm-side design docs live under `realms/realm-siliconsaga/docs/plans/`. From inside the nordri checkout alone these paths won't resolve — clone via `ws clone` to see them.
