# Kuttl Tests Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the outdated `validate.py` with kuttl BDD tests covering the Nordri platform substrate (ArgoCD, Gateway, Crossplane, Velero) and Nidavellir routing layer (ClusterIssuers, default cert, whoami end-to-end cert issuance).

**Architecture:** Two repos, each with their own kuttl config. Nordri has `kuttl-test-gke.yaml` pointing at `tests/e2e/shared/` and `tests/e2e/gke/`. Nidavellir has `kuttl-test.yaml` (platform assertions) and `kuttl-test-e2e.yaml` (whoami cert issuance, domain-dependent). All tests are pure assertions against a live cluster — no provisioning, just checking what ArgoCD already deployed is healthy.

**Tech Stack:** kubectl-kuttl v0.24.0 (`kubectl kuttl test`), Kubernetes YAML assertions, bash scripts in TestStep for HTTP checks. See the kuttl skill at `yggdrasil/.agent/skills/kuttl-testing/SKILL.md` for patterns and gotchas.

---

## Nordri tests

Run from `nordri/`: `kubectl kuttl test --config kuttl-test-gke.yaml`

### Task 1: Nordri directory structure + kuttl-test-gke.yaml

**Files:**
- Create: `kuttl-test-gke.yaml`
- Create: `tests/e2e/shared/.gitkeep`
- Create: `tests/e2e/gke/.gitkeep`

**Step 1: Create the kuttl config**

```yaml
# nordri/kuttl-test-gke.yaml
apiVersion: kuttl.dev/v1beta1
kind: TestSuite
testDirs:
  - tests/e2e/shared
  - tests/e2e/gke
timeout: 120
parallel: 1
skipDelete: false
```

`timeout: 120` — resources are already deployed; they should match immediately.
`parallel: 1` — sequential to avoid log interleaving on a shared cluster.
`skipDelete: false` — these are assert-only tests; nothing to delete.

**Step 2: Create directory stubs**

```bash
mkdir -p tests/e2e/shared/argocd
mkdir -p tests/e2e/shared/gateway
mkdir -p tests/e2e/shared/crossplane
mkdir -p tests/e2e/gke/velero
```

**Step 3: Verify kuttl can parse the config (expect no test cases yet)**

```bash
kubectl kuttl test --config kuttl-test-gke.yaml --dry-run 2>&1 | head -20
# Expected: no errors, "0 test(s)" or similar — just confirms config is valid
```

**Step 4: Commit**

```bash
git add kuttl-test-gke.yaml tests/
git commit -m "test: add kuttl-test-gke.yaml skeleton and test directory structure"
```

---

### Task 2: ArgoCD applications healthy assertion

**Files:**
- Create: `tests/e2e/shared/argocd/00-assert.yaml`

**Step 1: Write the assertion for all nordri-owned ArgoCD applications**

```yaml
# tests/e2e/shared/argocd/00-assert.yaml
# Assert nordri-owned ArgoCD applications are Synced and Healthy.
# nidavellir-owned apps (nidavellir, vegvisir, cert-manager) are asserted
# in nidavellir's own kuttl tests.
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
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: layer4-fundamentals
  namespace: argocd
status:
  health:
    status: Healthy
  sync:
    status: Synced
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: traefik
  namespace: argocd
status:
  health:
    status: Healthy
  sync:
    status: Synced
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: crossplane
  namespace: argocd
status:
  health:
    status: Healthy
  sync:
    status: Synced
```

**Step 2: Run and verify it passes**

```bash
kubectl kuttl test --config kuttl-test-gke.yaml --test argocd
# Expected: --- PASS: argocd (N.XXs)
```

**Step 3: Commit**

```bash
git add tests/e2e/shared/argocd/00-assert.yaml
git commit -m "test: assert nordri ArgoCD applications Synced+Healthy"
```

---

### Task 3: Gateway Programmed assertion

**Files:**
- Create: `tests/e2e/shared/gateway/00-assert.yaml`

**Step 1: Write the assertion**

```yaml
# tests/e2e/shared/gateway/00-assert.yaml
# Assert the Traefik Gateway is Programmed (listeners are valid and active).
# The Gateway lives in kube-system; Vegvísir (Nidavellir) owns it.
# We assert it here as part of the nordri shared substrate check because
# the Gateway's Programmed state confirms Traefik + cert-manager are wired correctly.
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

**Step 2: Run and verify it passes**

```bash
kubectl kuttl test --config kuttl-test-gke.yaml --test gateway
# Expected: --- PASS: gateway (N.XXs)
```

**Step 3: Commit**

```bash
git add tests/e2e/shared/gateway/00-assert.yaml
git commit -m "test: assert traefik-gateway is Programmed"
```

---

### Task 4: Crossplane providers and functions healthy assertion

**Files:**
- Create: `tests/e2e/shared/crossplane/00-assert.yaml`

**Step 1: Write the assertion**

```yaml
# tests/e2e/shared/crossplane/00-assert.yaml
# Assert all Crossplane providers and functions are Healthy.
# Providers: provider-helm, provider-kubernetes
# Functions: function-auto-ready, function-go-templating
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-helm
status:
  conditions:
  - type: Healthy
    status: "True"
---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-kubernetes
status:
  conditions:
  - type: Healthy
    status: "True"
---
apiVersion: pkg.crossplane.io/v1beta1
kind: Function
metadata:
  name: function-auto-ready
status:
  conditions:
  - type: Healthy
    status: "True"
---
apiVersion: pkg.crossplane.io/v1beta1
kind: Function
metadata:
  name: function-go-templating
status:
  conditions:
  - type: Healthy
    status: "True"
```

**Step 2: Run and verify it passes**

```bash
kubectl kuttl test --config kuttl-test-gke.yaml --test crossplane
# Expected: --- PASS: crossplane (N.XXs)
```

**Step 3: Commit**

```bash
git add tests/e2e/shared/crossplane/00-assert.yaml
git commit -m "test: assert Crossplane providers and functions Healthy"
```

---

### Task 5: Velero deployment running (GKE-only)

**Files:**
- Create: `tests/e2e/gke/velero/00-assert.yaml`

**Step 1: Write the assertion**

```yaml
# tests/e2e/gke/velero/00-assert.yaml
# Assert Velero deployment is running. On GKE this uses placeholder credentials
# (real GCS backup config is a TODO — see docs/velero-gke.md). The pod should
# boot and stay Running; a CrashLoopBackOff here means missing credentials.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: velero
  namespace: velero
status:
  readyReplicas: 1
```

**Step 2: Run and verify it passes**

```bash
kubectl kuttl test --config kuttl-test-gke.yaml --test velero
# Expected: --- PASS: velero (N.XXs)
```

**Step 3: Run the full nordri suite**

```bash
kubectl kuttl test --config kuttl-test-gke.yaml
# Expected: all 4 test cases PASS
# argocd, gateway, crossplane, velero
```

**Step 4: Commit**

```bash
git add tests/e2e/gke/velero/00-assert.yaml
git commit -m "test: assert Velero deployment readyReplicas=1 (GKE)"
```

---

## Nidavellir tests

Run from `nidavellir/`:
- Platform: `kubectl kuttl test --config kuttl-test.yaml`
- E2E: `WHOAMI_DOMAIN=test2.cmdbee.org kubectl kuttl test --config kuttl-test-e2e.yaml`

### Task 6: Nidavellir directory structure + vegvisir platform assertions

**Files:**
- Create: `nidavellir/kuttl-test.yaml`
- Create: `nidavellir/tests/e2e/vegvisir/00-assert.yaml`

**Step 1: Create the platform kuttl config**

```yaml
# nidavellir/kuttl-test.yaml
apiVersion: kuttl.dev/v1beta1
kind: TestSuite
testDirs:
  - tests/e2e/vegvisir
timeout: 120
parallel: 1
skipDelete: false
```

**Step 2: Create the vegvisir assertion**

```yaml
# nidavellir/tests/e2e/vegvisir/00-assert.yaml
# Assert nidavellir-owned ArgoCD applications are Synced+Healthy
# and all cert-manager issuers are Ready.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: nidavellir
  namespace: argocd
status:
  health:
    status: Healthy
  sync:
    status: Synced
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: vegvisir
  namespace: argocd
status:
  health:
    status: Healthy
  sync:
    status: Synced
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager
  namespace: argocd
status:
  health:
    status: Healthy
  sync:
    status: Synced
---
# Bootstrap self-signed cert must be Ready (Gateway depends on it)
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: traefik-gateway-default-cert
  namespace: kube-system
status:
  conditions:
  - type: Ready
    status: "True"
---
# Staging issuer Ready (used by whoami e2e and cert tests)
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-gateway-staging
status:
  conditions:
  - type: Ready
    status: "True"
---
# Production issuer Ready
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-gateway
status:
  conditions:
  - type: Ready
    status: "True"
```

**Step 3: Run and verify it passes**

```bash
cd /Users/cervator/dev/git_ws/nidavellir
kubectl kuttl test --config kuttl-test.yaml
# Expected: --- PASS: vegvisir (N.XXs)
```

**Step 4: Commit**

```bash
git -C /Users/cervator/dev/git_ws/nidavellir add kuttl-test.yaml tests/
git -C /Users/cervator/dev/git_ws/nidavellir commit -m "test: add nidavellir kuttl platform tests (vegvisir, issuers, default cert)"
```

---

### Task 7: Whoami end-to-end cert issuance test

**Files:**
- Create: `nidavellir/kuttl-test-e2e.yaml`
- Create: `nidavellir/tests/e2e/whoami/00-apply.yaml`
- Create: `nidavellir/tests/e2e/whoami/01-assert.yaml`
- Create: `nidavellir/tests/e2e/whoami/02-http.yaml`

This test applies the whoami demo app, waits for the staging cert to issue, then confirms HTTP traffic reaches the pod. It requires DNS to be pointing at the cluster (use `update-dns-namecheap.sh` first if needed).

**Step 1: Create the e2e kuttl config**

```yaml
# nidavellir/kuttl-test-e2e.yaml
# Domain-dependent e2e test — requires DNS A records pointing at the Traefik LB IP.
# Set WHOAMI_DOMAIN env var to override the test domain (default: test2.cmdbee.org).
# Run: WHOAMI_DOMAIN=test2.cmdbee.org kubectl kuttl test --config kuttl-test-e2e.yaml
#
# Uses letsencrypt-gateway-staging to avoid consuming production rate limits.
# A Ready staging cert proves the full pipeline: DNS → LB → HTTP-01 challenge → cert.
apiVersion: kuttl.dev/v1beta1
kind: TestSuite
testDirs:
  - tests/e2e/whoami
timeout: 300
parallel: 1
skipDelete: false
```

`timeout: 300` — 5 minutes allows for ACME challenge round-trip after cert-manager reconciles.

**Step 2: Create 00-apply.yaml — clean slate then apply whoami**

```yaml
# nidavellir/tests/e2e/whoami/00-apply.yaml
# Delete any existing whoami deployment (ensures cert issuance runs from scratch),
# then apply the demo app. The namespace deletion also removes any stale Certificate
# or CertificateRequest objects, forcing a clean ACME flow.
apiVersion: kuttl.dev/v1beta1
kind: TestStep
commands:
  - command: kubectl delete namespace demo-whoami --ignore-not-found
  - command: kubectl apply -f demos/whoami/whoami.yaml
```

Note: commands run with the working directory set to where `kuttl-test-e2e.yaml` lives (i.e. `nidavellir/`), so `demos/whoami/whoami.yaml` resolves correctly.

**Step 3: Create 01-assert.yaml — wait for cert to be Ready**

```yaml
# nidavellir/tests/e2e/whoami/01-assert.yaml
# Assert the staging certificate issued successfully.
# kuttl polls this until Ready=True or timeout (300s configured in kuttl-test-e2e.yaml).
# A Ready cert proves: ClusterIssuer contacted ACME, HTTP-01 challenge succeeded,
# cert-manager created the TLS secret.
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

**Step 4: Create 02-http.yaml — confirm HTTP traffic reaches the pod**

```yaml
# nidavellir/tests/e2e/whoami/02-http.yaml
# Confirm the HTTPRoute is routing traffic to the whoami pod.
# Uses $WHOAMI_DOMAIN env var (default: test2.cmdbee.org).
# Retries for up to 60s in case the HTTPRoute takes a moment to become active.
apiVersion: kuttl.dev/v1beta1
kind: TestStep
commands:
  - script: |
      set -e
      DOMAIN="${WHOAMI_DOMAIN:-test2.cmdbee.org}"
      echo "Testing HTTP routing: http://${DOMAIN}/"
      for i in $(seq 1 12); do
        STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://${DOMAIN}/")
        if [ "$STATUS" = "200" ]; then
          echo "✅ HTTP 200 from http://${DOMAIN}/"
          exit 0
        fi
        echo "  Got HTTP $STATUS (retry $i/12)..."
        sleep 5
      done
      echo "❌ Did not receive HTTP 200 from http://${DOMAIN}/ after 60s"
      exit 1
```

**Step 5: Run the e2e test against the live cluster**

Prerequisite: DNS must be pointing at the cluster LB IP. If not:
```bash
NAMECHEAP_API_USER=<user> NAMECHEAP_API_KEY=<key> \
  ./scripts/update-dns-namecheap.sh cmdbee.org \
  $(kubectl get svc traefik -n kube-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
```

Run the test:
```bash
cd /Users/cervator/dev/git_ws/nidavellir
WHOAMI_DOMAIN=test2.cmdbee.org kubectl kuttl test --config kuttl-test-e2e.yaml
# Expected:
# --- PASS: whoami (N.XXs)
# (will take up to ~2 minutes for ACME challenge)
```

**Step 6: Commit**

```bash
git -C /Users/cervator/dev/git_ws/nidavellir add kuttl-test-e2e.yaml tests/e2e/whoami/
git -C /Users/cervator/dev/git_ws/nidavellir commit -m "test: add whoami e2e kuttl test (staging cert issuance + HTTP routing)"
```

---

### Task 8: Update docs

**Files:**
- Modify: `nordri/docs/kuttl-tests.md`
- Modify: `nordri/docs/bootstrap.md`

**Step 1: Update kuttl-tests.md to reflect implemented state**

Add a "Running the tests" section at the top of `docs/kuttl-tests.md`:

```markdown
## Running the tests

### Nordri (platform substrate)

```bash
cd /path/to/nordri
kubectl kuttl test --config kuttl-test-gke.yaml
```

Covers: ArgoCD app health, Gateway Programmed, Crossplane providers/functions, Velero.

### Nidavellir (routing layer)

```bash
cd /path/to/nidavellir

# Platform assertions (fast, no external dependencies)
kubectl kuttl test --config kuttl-test.yaml

# End-to-end cert issuance (requires DNS — run after bootstrap + DNS update)
WHOAMI_DOMAIN=test2.cmdbee.org kubectl kuttl test --config kuttl-test-e2e.yaml
```
```

**Step 2: Update bootstrap.md validation section**

Replace the validation note at the bottom of `docs/bootstrap.md`:

```markdown
## Validation

After bootstrap completes and DNS is updated, run the full test suite:

```bash
# Nordri platform substrate
kubectl kuttl test --config kuttl-test-gke.yaml

# Nidavellir routing layer
cd ../nidavellir
kubectl kuttl test --config kuttl-test.yaml

# End-to-end cert issuance (requires DNS to be propagated)
WHOAMI_DOMAIN=test2.cmdbee.org kubectl kuttl test --config kuttl-test-e2e.yaml
```

`validate.py` is retained for quick human-readable homelab smoke checks but is
no longer the primary validation mechanism.
```

**Step 3: Commit**

```bash
git add docs/kuttl-tests.md docs/bootstrap.md
git commit -m "docs: update kuttl-tests.md and bootstrap.md with running instructions"
```
