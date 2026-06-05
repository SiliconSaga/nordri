---
name: nordri
description: "Use when bootstrapping Nordri on a fresh cluster, debugging the layered install order, or asking why bootstrap deviates from pure ArgoCD. Captures the judgment behind the layering + gotchas not documented in `bootstrap.sh`. Defers facts (versions, layer specifics, Garage init steps) to `bootstrap.sh` + `platform/fundamentals/manifests/crossplane-providers.yaml` directly."
---

# nordri

Bootstrap is `bootstrap.sh [gke|homelab]`. The script has thorough inline comments explaining each numbered layer; this skill captures the *judgment* behind the layering and the gotchas that aren't documented inline.

## When to Use

- Fresh-cluster bootstrap on homelab (Rancher Desktop) or GKE.
- "Why is X installed via Helm directly and not ArgoCD?"
- Garage init failures, Velero credentials missing, ArgoCD adoption issues.
- Understanding why ArgoCD lives in namespace `argo` (not `argocd`) and how seed-Gitea fits.

NOT for generic ArgoCD GitOps patterns — sibling skill [`argocd-gitops`](../argocd-gitops/SKILL.md) covers test-through-Git, app-of-apps prune cascade, SSA for large CRDs. NOT for Crossplane Composition Pipeline-mode patterns — sibling skill [`crossplane-compositions`](../crossplane-compositions/SKILL.md) covers `crossplane render`, CEL readiness, CompositionRevision flapping.

## The Layering Principle

Pre-ArgoCD layers exist because ArgoCD can't sync resources whose CRDs don't exist yet. Traefik registers `IngressRoute` / `Middleware` / Gateway-API CRDs; Crossplane providers register `ProviderConfig` CRDs. Without that ordering, the post-ArgoCD sync floods with "no matches for kind" errors. Once installed via raw Helm, ArgoCD adopts the running releases at the root-app layer (same release name/namespace → seamless takeover).

For the layer-by-layer specifics (which layer installs what, version pins, Garage init steps), read `bootstrap.sh` directly. It's the source of truth and is well-commented.

## Judgment Calls Worth Knowing

These are bootstrap decisions that aren't self-evident from the script:

- **Traefik chart pinned to `38.x` / app `3.6.5` deliberately.** Chart 38+ bundles the Gateway API CRDs (avoiding a field-manager conflict a separate CRD apply used to cause). App `3.7.x` reintroduces a Gateway-provider cert regression. Don't bump blindly — verify upstream resolution first.
- **Velero credentials on GKE are a placeholder.** The bootstrap pre-creates a `velero-credentials` Secret to prevent CrashLoopBackOff during initial ArgoCD sync (Velero needs a Secret to start). Until GKE Velero is wired for **GCS + Workload Identity** (see `docs/velero-gke.md`), Velero is non-functional on GKE — but bootstrap is clean.
- **Garage init is homelab-only.** GKE's Velero target will be GCS via Workload Identity (keyless), not S3-via-Garage. Don't try to run the homelab Garage init flow on GKE.
- **Seed-Gitea is ephemeral by design.** Uses the chart's bundled Postgres + Valkey with `persistence.enabled=false` — it exists only to break the chicken-and-egg of "ArgoCD needs a Git source, but GitHub can't reach the cluster API during bootstrap." Day-2 plan to graduate to persistent Forgejo lives realm-side under `realms/realm-siliconsaga/docs/plans/`.
- **ArgoCD namespace is `argo`, not `argocd`.** Reserved to avoid colliding with legacy installations on the same cluster.

## Gotchas Not in `bootstrap.sh`

- **Helm `--set watchNamespace=""`** is silently ignored on most operators. Use `watchAllNamespaces=true`. (Also covered in sibling `crossplane-compositions`.)
- **Git Bash MSYS path mangling.** `kubectl exec pod -- /garage <cmd>` from Git Bash converts `/garage` to `C:/Program Files/Git/garage`. Prefix with `MSYS_NO_PATHCONV=1` or run from PowerShell. Bootstrap already does this internally; manual ad-hoc `kubectl exec` commands need the same treatment.
- **Garage `replicationFactor > node count`.** Homelab is single-node (layout 1/1). Multi-node homelab needs `replicationFactor` adjusted via Garage chart values override.

## Where to Read the Current State

In-repo (run from the nordri checkout):

- `bootstrap.sh` — source of truth for layer sequence, version pins, and Garage init flow. Inline comments explain *why* each layer exists.
- `platform/fundamentals/manifests/crossplane-providers.yaml` — provider + function versions.
- `platform/root-app.yaml` — the entry point ArgoCD adopts.
- `docs/velero-gke.md` — Velero on GKE TODO (GCS + Workload Identity).

Cross-repo (yggdrasil workspace — requires `ws clone`, or follow the GitHub links below):

- Sibling skills: [`argocd-gitops`](../argocd-gitops/SKILL.md), [`crossplane-compositions`](../crossplane-compositions/SKILL.md).
- Realm narrative: [`SiliconSaga/realm-siliconsaga: docs/stack-tier-1.md`](https://github.com/SiliconSaga/realm-siliconsaga/blob/main/docs/stack-tier-1.md) (workspace path: `realms/realm-siliconsaga/docs/stack-tier-1.md`).
- [`SiliconSaga/nidavellir: vegvisir/README.md`](https://github.com/SiliconSaga/nidavellir/blob/main/vegvisir/README.md) — post-bootstrap Application re-pointing transition notes (workspace path: `components/nidavellir/vegvisir/README.md`).
