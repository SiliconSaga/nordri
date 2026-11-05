# Nordri — Cluster Substrate (Tier 1)

Nordri is the foundation layer: Traefik, Crossplane, Velero, Garage S3.
(Longhorn was retired 2026-08-26 — storage is `local-path`.)
ArgoCD is bootstrapped here and deploys everything above via `nidavellir-apps.yaml`.

**Full agent context:** [`yggdrasil/CLAUDE.md`](../yggdrasil/CLAUDE.md) and
[`yggdrasil/docs/ecosystem-architecture.md`](../yggdrasil/docs/ecosystem-architecture.md)

---

## Key Commands

### Push changes to in-cluster Gitea (after local edits)
```bash
./update-embedded-git.sh gke
```
By default the script kubectl-port-forwards to `localhost:3000`. To push
via the Gitea HTTPRoute instead (recommended on clusters where the
ingress is wired up — and required when the local git credential
manager intercepts localhost):

```bash
GITEA_HOST=gitea.cmdbee.org ./update-embedded-git.sh gke
GITEA_HOST=gitea.localhost  ./update-embedded-git.sh homelab
```

Admin credentials are read from `gitea/gitea-admin-credentials` (created
by `bootstrap.sh` on fresh installs). Retrieve with:

```bash
kubectl get secret -n gitea gitea-admin-credentials \
  -o jsonpath='{.data.password}' | base64 --decode
```

If ArgoCD doesn't auto-sync after push, refresh the app that **owns the changed
resource**. A refresh does not cascade from a parent app to its children, so
hitting the root alone will not pick up a leaf's manifest change:

```bash
kubectl annotate application nordri-root -n argo argocd.argoproj.io/refresh=hard --overwrite  # app-of-apps (platform/argocd)
kubectl annotate application keycloak    -n argo argocd.argoproj.io/refresh=hard --overwrite  # the leaf that owns the resource
```

`kubectl get application -n argo -o custom-columns=NAME:.metadata.name,REPO:.spec.source.repoURL,PATH:.spec.source.path`
maps a hydrated path back to the app to refresh. Note `vegvisir` is a leaf
(cert-manager, the ClusterIssuer and the traefik Gateway), not the root.

### Run kuttl tests (GKE)
```bash
kubectl kuttl test --config kuttl-test-gke.yaml
# Tests: argocd, gateway, crossplane (shared); velero (GKE)
```

### Provision a fresh GKE test cluster
```bash
./gke-provision.sh
```

---

## Key Gotchas

- **kuttl CWD**: `commands:` steps run from the test case directory, not the project root.
  Use `../../../` to reach project-root files. See kuttl-testing skill.
- **kuttl conditions**: assertions on `status.conditions` arrays must include ALL conditions
  the live resource has — not just the one you care about. Check with `kubectl get -o yaml`.
- **ArgoCD webhook drift**: Kubernetes defaulting webhooks add `group:` fields at admission
  time. These must be present in git manifests to avoid OutOfSync. Already fixed for Traefik
  Gateway and cert-manager resources — see `MEMORY.md` for the full list.
- **Seed Gitea uses SQLite** intentionally (bootstrap simplicity), and `bootstrap.sh` now
  pins that explicitly. It had drifted: the chart defaults `postgresql-ha.enabled=true` and
  `valkey-cluster.enabled=true`, so a reinstall silently brought up 8 pods (3-replica
  Postgres + pgpool, 3-node Valkey) and 1300m of CPU requests for a disposable seed — while
  this line still claimed SQLite. Note `persistence.enabled=false` disables only Gitea's own
  volume, not the subcharts'. Do not thin Valkey by scaling replicas: it runs in cluster mode
  and sharding breaks below 3 (`cluster_state:fail`). Turn it off instead.
- **Forgejo is the intended path for persistent GitOps**; the seed Gitea should stay
  disposable rather than being hardened. Vending its database from Mimir is therefore no
  longer the plan for the seed (nordri#2 predates that decision).
