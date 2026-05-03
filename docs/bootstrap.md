# Nordri Bootstrapping Strategy

This document details the bootstrapping process for Nordri clusters (GKE and Homelab).
It solves the "Chicken and Egg" problem of GitOps (ArgoCD needing a repo to install
itself) by injecting a **Seed Gitea** as the very first step.

**Nordri covers Layers 2–4.** Layers 5+ (platform services, user workloads) belong to
Nidavellir and Demicracy — separate repos deployed by ArgoCD once Nordri is stable.

## Bootstrap Layers

### Layer 1 — The Substrate (Kubernetes)
Provision the raw cluster before running any scripts.

- **GKE**: `./gke-provision.sh create`
- **Homelab**: k3s/Rancher Desktop, pre-existing

### Layer 2 — The Seed (Gitea + Nidavellir hydration)
`./bootstrap.sh [gke|homelab]`

- Installs **Gitea** (Helm, `gitea` namespace, ephemeral — no persistence)
- **Resolves Gitea admin credentials** and persists them to the
  `gitea/gitea-admin-credentials` Secret. On a fresh install the script
  generates a strong random password (~140 bits via `openssl rand`); on a
  re-run it reuses whatever's already in the Secret. Existing pre-Secret
  clusters get the historical default (`nordri-password-change-me`)
  captured into the Secret on first re-run so subsequent scripts can read
  from one place. Override with `GITEA_USER` / `GITEA_PASS` env vars.
- Creates Nordri and Nidavellir repos in Gitea via API
- Hydrates both repos from local checkouts (applies target overlay for Nordri)
- Nidavellir is expected as a sibling directory; override with `NIDAVELLIR_DIR`

Retrieve the active password:

```bash
kubectl get secret -n gitea gitea-admin-credentials \
  -o jsonpath='{.data.password}' | base64 --decode
```

### Layer 2.5 — Gateway API CRDs + Crossplane Core
- Installs **Gateway API CRDs** (required before Traefik's GatewayClass can register)
- Installs **Crossplane Core** (CRDs must exist before ArgoCD syncs ProviderConfigs)

### Layer 2.6 — Traefik (pre-ArgoCD)
- Installs **Traefik** via Helm into `kube-system`
- Registers `IngressRoute` CRDs needed by any ArgoCD-managed IngressRoute resources
- Sets `gateway.enabled=false` — the Gateway resource is owned by Vegvísir (Nidavellir)
- On GKE: provisions the LoadBalancer service (source of the cluster's external IP)

### Layer 2.7 — Crossplane Providers + Functions
- Applies `crossplane-providers.yaml` and waits for all providers to become Healthy
- Must be healthy before ProviderConfigs (Layer 2.8) can be applied
- Functions: `function-auto-ready`, `function-go-templating`,
  `function-environment-configs`. The last one is required for the
  cluster-identity pattern — see [`cluster-identity.md`](cluster-identity.md)
  for how downstream compositions consume per-environment values
  (`storageClass`, `domain`, etc.) without claim parameters or per-environment
  hydration

### Layer 2.8 — Crossplane ProviderConfigs + RBAC
- Applies `crossplane-configs.yaml` (ProviderConfig CRDs now exist from Layer 2.7)

### Layer 3 — ArgoCD
- Installs **ArgoCD** via Helm (`argocd` namespace)
- Applies the Root Application pointing at internal Gitea → ArgoCD takes over

### Layer 4 — Fundamentals (ArgoCD-managed)
ArgoCD syncs the Nordri app-of-apps. Components vary by target:

| Component | GKE | Homelab |
|---|---|---|
| Traefik (adopted by ArgoCD) | ✅ | ✅ |
| Crossplane (adopted by ArgoCD) | ✅ | ✅ |
| Velero | ✅ (placeholder creds) | ✅ (Garage S3) |
| Longhorn | ❌ | ✅ |
| Garage S3 | ❌ | ✅ |

cert-manager is **not** a Nordri Layer 4 component. It is deployed by
Vegvísir (Nidavellir Tier 2) via ArgoCD sync-waves after Nordri stabilises.

### Nidavellir (Tier 2) — Platform Services
ArgoCD syncs Nidavellir from the internal Gitea. Vegvísir deploys in sync-wave order:

| Wave | Resource |
|---|---|
| 10 | cert-manager |
| 11 | SelfSigned ClusterIssuer (bootstrap) |
| 12 | traefik-gateway-default-cert Certificate |
| 13 | Traefik Gateway resource |
| 15 | letsencrypt-gateway-staging + letsencrypt-gateway ClusterIssuers |

## Post-Bootstrap (GKE)

After the root app is applied the bootstrap script waits for the Traefik LB IP.
cert-manager and the Gateway deploy automatically via ArgoCD.

### Automated DNS (recommended)

Set these env vars before running `bootstrap.sh` to have DNS updated automatically:

```bash
export NAMECHEAP_API_USER=your-username
export NAMECHEAP_API_KEY=your-api-key
export NAMECHEAP_DOMAIN=cmdbee.org   # default; override for other domains
./bootstrap.sh gke
```

The script updates `@` and `*` A records to the Traefik LB IP via the NameCheap API,
then cert-manager can issue certs as soon as DNS propagates (~1–5 minutes).

**One-time NameCheap setup:**
1. Log in → Profile → Tools → API Access → Enable API
2. Whitelist your public IP: `curl https://api.ipify.org`
3. Copy the API key

If the call fails (e.g. your IP changed), `bootstrap.sh` falls back to manual
instructions. Re-run `scripts/update-dns-namecheap.sh` once the whitelist is updated.

**Testing the script without touching real DNS:**

```bash
NAMECHEAP_API_USER=sandboxuser NAMECHEAP_API_KEY=sandboxkey \
  NAMECHEAP_SANDBOX=true \
  ./scripts/update-dns-namecheap.sh cmdbee.org 1.2.3.4
```

Requires a separate account at [sandbox.namecheap.com](https://www.sandbox.namecheap.com).

### Manual DNS (fallback)

If credentials are not set, `bootstrap.sh` prints the LB IP and these steps:
1. Point `@` and `*` A records at the printed Traefik LB IP at your registrar
2. Test cert issuance with `letsencrypt-gateway-staging` before using production
   (see `nidavellir/demos/whoami/` for a ready-made validation app)

## Updating a running cluster

To push local changes to Gitea without reinstalling anything:

```bash
./update-embedded-git.sh [gke|homelab]
```

This re-hydrates both the Nordri and Nidavellir repos and triggers an ArgoCD sync.

### Talking to Gitea over a real ingress (skipping port-forward)

By default the script reaches Gitea via `kubectl port-forward` to
`localhost:3000`. On clusters that already have the Gitea HTTPRoute
deployed (see `platform/fundamentals/ingress/gitea-{homelab,gke}.yaml`)
you can skip the port-forward by setting `GITEA_HOST`:

```bash
GITEA_HOST=gitea.cmdbee.org ./update-embedded-git.sh gke
GITEA_HOST=gitea.localhost  ./update-embedded-git.sh homelab
```

Useful when:
- Workstation's git credential manager intercepts `localhost:3000`
  (notably Windows Git Credential Manager + a `provider=generic` config).
- Gitea is reachable directly via DNS and the port-forward is just
  overhead.

`GITEA_SCHEME` (default `http`) controls the URL scheme; once the
Vegvísir wildcard cert lands on the Gateway listener, set
`GITEA_SCHEME=https` to encrypt credential traffic.

### Credentials

Both `bootstrap.sh` and `update-embedded-git.sh` read the Gitea admin
credentials from the `gitea/gitea-admin-credentials` Secret. Override
with `GITEA_USER` / `GITEA_PASS` env vars on either script. See the
script headers for the full resolution order.

## Diagrams

### Bootstrap sequence (L2–L4)

```mermaid
graph TD
    Local[Local Machine] -->|gke-provision.sh| L1[L1: GKE Cluster]
    Local -->|bootstrap.sh| L2[L2: Seed Gitea]
    L2 --> L25[L2.5: Gateway API CRDs + Crossplane]
    L25 --> L26[L2.6: Traefik]
    L26 --> L27[L2.7: Crossplane Providers]
    L27 --> L28[L2.8: ProviderConfigs]
    L28 --> L3[L3: ArgoCD]
    L3 -->|Root App| L4[L4: Fundamentals]
    L3 -->|Nidavellir App| N[Vegvísir / Mimir / Heimdall / ...]
```

### ArgoCD sync-wave ordering (Nidavellir/Vegvísir)

```mermaid
graph LR
    CM[cert-manager\nwave 10] --> SI[SelfSigned Issuer\nwave 11]
    SI --> DC[Default Cert\nwave 12]
    DC --> GW[Gateway\nwave 13]
    GW --> LE[LetsEncrypt Issuers\nwave 15]
```

## Validation

After bootstrap completes and DNS is updated, run the full test suite:

```bash
# Nordri platform substrate
kubectl kuttl test --config kuttl-test-gke.yaml

# Nidavellir routing layer (assumes nidavellir is a sibling directory)
cd ../nidavellir
kubectl kuttl test --config kuttl-test.yaml

# End-to-end cert issuance (requires DNS to be propagated)
WHOAMI_DOMAIN=test.cmdbee.org kubectl kuttl test --config kuttl-test-e2e.yaml
```

See `docs/kuttl-tests.md` for full test structure and design notes.
