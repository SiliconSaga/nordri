# Kuttl Test Design — Nordri + Nidavellir

## Context

Mimir has kuttl e2e tests that apply Crossplane claims and assert they reach Ready.
Nordri and Nidavellir need equivalent coverage asserting that the platform substrate
and routing layer are correctly deployed and functional.

`validate.py` currently serves this role for Nordri but is homelab-centric and
outdated. The plan is to replace it with kuttl tests that:
- Cover both `gke` and `homelab` targets (via tags or separate test dirs)
- Follow the same `00-apply / 01-assert` pattern as Mimir
- Include an end-to-end cert issuance test using the whoami demo app

A kuttl skill exists in the workspace — invoke it when implementing.

## Test Structure

```
nordri/
  kuttl-test.yaml
  tests/
    e2e/
      argocd/
        00-assert.yaml     # ArgoCD apps Synced + Healthy
      gateway/
        00-assert.yaml     # Gateway Programmed, listeners valid
      crossplane/
        00-assert.yaml     # Providers + Functions Healthy
      velero/
        00-assert.yaml     # Velero deployment Running

nidavellir/
  kuttl-test.yaml
  tests/
    e2e/
      vegvisir/
        00-assert.yaml     # ClusterIssuers Ready, default cert Ready
      whoami/              # Domain-dependent — skip if no DNS
        00-apply.yaml      # kubectl apply demos/whoami/whoami.yaml
        01-assert.yaml     # Certificate whoami-cert Ready
        02-http.yaml       # curl http://test.<domain>/ returns 200
```

## Tagging Strategy

kuttl does not have native tag support, but test directories can be organised by
target. Options:

**Option A — separate test dirs per target:**
```
tests/e2e/gke/argocd/
tests/e2e/homelab/argocd/
tests/e2e/shared/argocd/
```
Run with `kubectl kuttl test --test-dir tests/e2e/shared tests/e2e/gke`

**Option B — single dir with skip conditions:**
Use `00-assert.yaml` conditions that naturally pass/fail based on what's installed.
For example, a Longhorn assert will simply not find the namespace on GKE and fail,
so homelab-only tests live in a separate `homelab/` subdir that's excluded for GKE runs.

Recommendation: **Option B** with a `shared/`, `gke/`, and `homelab/` split under
`tests/e2e/`. The kuttl-test.yaml per target specifies which dirs to run.

## Key Assertions to Write

### Shared (both targets)

**ArgoCD applications healthy:**
```yaml
# 00-assert.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: nordri-root
  namespace: argocd
status:
  health:
    status: Healthy
  sync:
    status: Synced
```

**Gateway Programmed:**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: traefik-gateway
  namespace: kube-system
status:
  conditions:
  - type: Programmed
    status: "True"
```

**ClusterIssuers Ready:**
```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-gateway-staging
status:
  conditions:
  - type: Ready
    status: "True"
```

### GKE-only

**Velero deployment running** (placeholder creds — pod should boot, not crash):
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: velero
  namespace: velero
status:
  readyReplicas: 1
```

### Homelab-only

**Longhorn pods healthy, Garage pod healthy** (existing validate.py logic, ported).

### Domain-dependent (whoami e2e — requires DNS + flagged optional)

Apply `nidavellir/demos/whoami/whoami.yaml` (with domain substituted), then assert:
```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: whoami-cert
  namespace: demo-whoami
status:
  conditions:
  - type: Ready
    status: "True"
```

The domain in the whoami test should be configurable (env var substitution or
a separate values file) so it's not permanently hardcoded in the assertion. The
README in `nidavellir/demos/whoami/` already advises users to set their domain.

## What Happens to validate.py

Once kuttl tests cover the same ground, `validate.py` can be retired. In the
interim it remains as a quick human-readable smoke check, but its pod-health
and PVC checks are duplicated by kuttl assertions and should not be maintained
in parallel long-term.
