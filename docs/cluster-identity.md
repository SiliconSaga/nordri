# Cluster Identity

Every cluster Nordri bootstraps carries one set of per-cluster facts — its name,
environment, role, maturity, domain, storage class, GCP project, tailnet node. They
live **on the cluster**, not in Git: nothing is stamped into manifests at hydration,
and the same Git content applies identically to every cluster.

`scripts/identity.sh apply <realm> <cluster>` resolves the facts and writes them in
three places: a ConfigMap, an ArgoCD cluster Secret, and a Crossplane
`EnvironmentConfig`.

## The problem it solves

A composition or an Application needs to know *which* cluster it is on to pick the
right StorageClass, ingress domain, overlay or backup path. The historical answers
were a required `parameters.environment` field on every claim, per-step ternaries in
every composition, and placeholders substituted into manifests per cluster at
hydration. None scales, and the last one meant the same Git repo could not be applied
identically to homelab and GKE.

Cluster identity inverts the relationship: the *cluster* declares its facts once, and
everything else reads them.

## The ConfigMap and its three layers

The source of truth on the cluster is `ConfigMap nordri/cluster-identity`. Its keys
are resolved from three layers, later winning:

1. `identity/defaults-<environment>.yaml` in nordri — what every cluster of that
   environment shares (storage class, domain, region).
2. The realm's `clusters/<cluster>.yaml` — what is specific to this cluster.
3. `NORDRI_IDENTITY_<KEY>` environment variables — for values that must never be
   committed. None exist today.

Files are flat `key: value` only; nesting is refused.

Worked example, `clusters/homelab-prod.yaml` in the realm:

```yaml
environment: homelab
role: prod
maturity: durable
```

The `homelab` defaults supply `storageClass: local-path` and the homelab domain; the
cluster file supplies the role and maturity; the cluster name comes from the file name
(and the argument to `identity.sh`). `environment`, `role` and `maturity` are
required in a realm file. `role` is `lab`, `test` or `prod`; `maturity` is
`bootstrap`, `durable` or `full` and gates the durable tier (realm design
`2026-09-07-forgejo-day2-design.md`). A `gke` cluster must also declare `gcpProject`.
A `prod` cluster carries a `sourceRef` (`main` or `live`).

A cluster with no realm file is a bootstrap lab: `homelab`, `lab`, `bootstrap`. There
is nothing to write to try Nordri out.

**Name guard.** The cluster name must be a DNS-1123 label of at most 63 characters,
because it ends up in label values, paths (the Velero prefix) and tailnet names.
`identity.sh` also never renames a cluster: if the live ConfigMap names a different
cluster, it refuses, and the answer is to re-bootstrap.

**`tailnetNode`.**

- unset on a `prod` cluster: the node is the cluster name (unique in the realm);
- unset on `lab` or `test`: empty, meaning no tailnet operator;
- `stamped`: `<cluster>-<yyyymmdd-HHMM>`, for lab and test clusters that come and go.
  A live stamp is kept on re-apply, so a device is never renamed under a running
  cluster.

**Graduation** is "edit the realm file, merge, `identity.sh apply`" — for example
raising `maturity` from `bootstrap` to `durable`. The apply prints a diff of resolved
versus live before writing.

## The two projections, and who reads which

| Projection | Holds | Read by |
|---|---|---|
| `EnvironmentConfig/cluster-identity` (Crossplane) | the identity's non-empty values as `data:` | compositions, via `function-environment-configs` |
| ArgoCD cluster Secret `argo/in-cluster` | labels `nordri.siliconsaga.org/{cluster,environment,role,tailnet}`; annotations `nordri.siliconsaga.org/{tailnet-node,gcp-project,maturity}` | ApplicationSets, via the cluster generator |

Nordri's two ApplicationSets read the Secret: `layer4-fundamentals` picks
`platform/fundamentals/overlays/<environment>`, and `velero` generates only where the
environment is `gke`, taking the project from `gcp-project` and the backup prefix from
the cluster name. Both guard every lookup with `fail` (an absent key would otherwise
render as an empty string), and both set `preserveResourcesOnDeletion` and
`applicationsSync: create-update` so a generator that matches nothing cannot delete
what it deployed.

## How a composition consumes it

Two pipeline steps. **Step 0** loads the EnvironmentConfig into the request
context; subsequent `function-go-templating` steps read from
`.context."apiextensions.crossplane.io/environment"`:

```yaml
spec:
  pipeline:
  - step: load-cluster-identity
    functionRef:
      name: function-environment-configs
    input:
      apiVersion: environmentconfigs.fn.crossplane.io/v1beta1
      kind: Input
      spec:
        environmentConfigs:
        - type: Reference
          ref:
            name: cluster-identity

  - step: render-resources
    functionRef:
      name: function-go-templating
    input:
      apiVersion: gotemplating.fn.crossplane.io/v1beta1
      kind: GoTemplate
      source: Inline
      inline:
        template: |
          {{- $identity := index .context "apiextensions.crossplane.io/environment" -}}
          {{- $storageClass := $identity.storageClass -}}
          {{- $domain := $identity.domain -}}
          # ... use $storageClass, $domain, $identity.environment ...
```

The Go template key contains slashes and dots, so use Go's `index` rather than
dotted access. Common idiom: bind `$identity` once at the top of the template
and reference fields off it.

## Optional claim overrides

Claim parameters are still useful as a per-claim escape hatch. The convention:
a claim parameter, if present, overrides the cluster-identity value. Sprig's
`default` makes this a one-liner:

```go
{{- $env := .observed.composite.resource.spec.parameters.environment | default $identity.environment -}}
{{- $domain := .observed.composite.resource.spec.parameters.domain | default $identity.domain -}}
```

The XRD declares the parameter without a `default:` and without listing it in
`required:`, so claims can omit it entirely:

```yaml
parameters:
  type: object
  properties:
    environment:
      type: string
      enum: ["homelab", "gke"]
      description: "Optional override for the target environment. Defaults to EnvironmentConfig/cluster-identity."
    domain:
      type: string
      description: "Optional override for the ingress base domain. Defaults to EnvironmentConfig/cluster-identity."
```

## Adding a new field

Extend cluster identity when a new fact is environment-dependent and shared
across compositions. Examples that would belong:

- An `objectStoreEndpoint` once Garage/Seaweed/GCS becomes common across
  observability, backup, and platform components
- An `oidcIssuerUrl` once Keycloak issues IDs cluster-wide
- A `defaultPullSecret` reference for private registries

To add one:

1. Add the key to `IDENTITY_KEYS` in `lib/identity.sh` and give it a value in each
   `identity/defaults-<environment>.yaml` (or leave it to the realm's cluster files).
   The resolver prints every key, empty when unset, so readers can rely on the shape.
2. If an ApplicationSet needs it, project it onto the cluster Secret in
   `scripts/identity.sh` and guard the lookup with `fail`.
3. Compositions that want it read it the same way:
   `{{ $identity.objectStoreEndpoint }}`.
4. Update this doc.

Avoid putting per-claim or per-workload settings here. Cluster identity is
about cluster-wide facts; resource sizing, retention, feature flags belong on
the claim.

## Why a function instead of `spec.environment.environmentConfigs`

Crossplane v1 Compositions had a `spec.environment.environmentConfigs` field
that Crossplane itself merged into the request context. v2 removed it; the
v2-native pattern is to call `function-environment-configs` explicitly as a
pipeline step. Bonus: the function model composes well with multiple
EnvironmentConfigs (e.g. cluster identity *plus* a per-tenant overlay) and
keeps composition logic visible in the pipeline rather than hidden in a
top-level field.

## See also

- Heimdall is the proving ground — see
  [`heimdall/crossplane/composition.yaml`](https://github.com/SiliconSaga/heimdall/blob/main/crossplane/composition.yaml)
  (separate repo).
- Function source:
  https://github.com/crossplane-contrib/function-environment-configs
- `function-go-templating` template syntax:
  https://github.com/crossplane-contrib/function-go-templating
