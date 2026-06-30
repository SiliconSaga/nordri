# Resolving `keycloak.localhost` inside the cluster (homelab CoreDNS rewrite)

On homelab, a CoreDNS drop-in rewrites the name `keycloak.localhost` to the in-cluster Traefik Service so that **pods** — not just browsers — can reach Keycloak at its homelab issuer URL. This page explains why that is needed, how the rewrite works, and how to verify it. The manifest is `platform/fundamentals/manifests/coredns-custom-homelab.yaml`, referenced only from the homelab overlay.

## Why it's needed: the OIDC split-horizon problem

Keycloak runs in Hostname-v2 **dynamic** mode (`keycloak/keycloak.yaml`, `hostname.strict: false`). The OIDC `issuer` it advertises follows the request host: `http://keycloak.localhost` on homelab, `https://keycloak.cmdbee.org` on GKE. A pinned hostname would make the issuer unreachable from a homelab browser, so dynamic mode is deliberate.

Browsers resolve any `*.localhost` name to `127.0.0.1` for free (RFC 6761), so the **browser leg** of an OIDC login — the redirect to Keycloak's authorization endpoint — works without any help. The trouble is the **server leg**.

OpenBao's OIDC auth method (the first consumer; it backs leidangr's `scripts/dev-secrets` → `bao login -method=oidc`) derives *every* endpoint — authorization, token, JWKS — from a single discovery document, and it validates the ID token's `iss` claim strictly. There is no "discover here, redirect the browser somewhere else" split the way oauth2-proxy offers (`--insecure-oidc-skip-issuer-verification`, used by the SSO demo). So every actor has to agree on one issuer: `http://keycloak.localhost/realms/<realm>`.

But the OpenBao **pod** performs the authorization-code → token exchange server-to-server, and cluster DNS has no record for `keycloak.localhost` — it is a browser/RFC-6761 convention, not a real DNS zone. Without a rewrite the pod's lookup fails and `bao login -method=oidc` never completes (the browser logs in, then the CLI hangs/errors on the token exchange). The same trap will bite any in-cluster client that has to reach a `*.localhost` homelab service server-side.

## How the rewrite works

k3s ships CoreDNS with two import directives in its Corefile: `import /etc/coredns/custom/*.override` **inside** the `.:53 { … }` server block, and `import /etc/coredns/custom/*.server` at the top level. The CoreDNS Deployment mounts an **optional** ConfigMap named `coredns-custom` (in `kube-system`) at `/etc/coredns/custom`. Any data key ending in `.override` is injected as directives *within* the server block — so we never edit the k3s-managed `coredns` ConfigMap, which k3s would revert on restart.

Our `keycloak.override` key contains:

```
rewrite stop {
  name exact keycloak.localhost traefik.kube-system.svc.cluster.local
  answer auto
}
```

- `name exact keycloak.localhost …` rewrites only that one name to the cluster-internal Traefik Service. `exact` keeps the blast radius to a single name — no other `*.localhost` is affected.
- Traefik already routes the `keycloak.localhost` Host to Keycloak via the `keycloak-localhost` HTTPRoute, so once the pod reaches Traefik on port 80 with that Host header, the request lands on Keycloak.
- `answer auto` rewrites the response's owner name from `traefik.kube-system.svc.cluster.local` back to `keycloak.localhost`. Without it the A record comes back owned by the Traefik name and a strict resolver (Go, in the OpenBao pod) discards it as a question/answer name mismatch. This is the easy-to-miss part: the bare two-argument `rewrite name … …` form is *not* enough on its own.

## Scope: homelab only

This rewrite is wrong on GKE, where `keycloak.cmdbee.org` has real public DNS and TLS. The manifest is therefore referenced **only** from `platform/fundamentals/overlays/homelab/kustomization.yaml`. The GKE overlay does not include it.

## Deployment and reproducibility

The manifest is part of the homelab fundamentals overlay, which the platform app-of-apps points ArgoCD at (path patched to `overlays/homelab` by `bootstrap.sh`). So a fresh homelab bootstrap recreates the `coredns-custom` ConfigMap automatically; there is nothing manual to remember on rebuild.

CoreDNS does not always re-hash imported drop-ins on its own when the ConfigMap changes, so after a *change* to this file force a reload:

```bash
kubectl -n kube-system rollout restart deploy/coredns
```

(First-time creation on a running cluster also wants the restart; a from-scratch bootstrap starts CoreDNS after the ConfigMap exists, so it picks it up on boot.)

## Verify

Resolve the name from inside the OpenBao pod (any pod works — it is cluster-wide DNS):

```bash
kubectl -n openbao exec openbao-0 -- nslookup keycloak.localhost
# Name: keycloak.localhost  →  Address: <Traefik ClusterIP>
```

Then confirm the full HTTP path through Traefik returns Keycloak's discovery document with the `keycloak.localhost` issuer:

```bash
kubectl -n openbao exec openbao-0 -- \
  wget -qO- http://keycloak.localhost/realms/siliconsaga/.well-known/openid-configuration
# "issuer":"http://keycloak.localhost/realms/siliconsaga", …
```

If the first command resolves but the second hangs or 404s, check that the `keycloak-localhost` HTTPRoute is attached to the Traefik Gateway's `web` listener.
