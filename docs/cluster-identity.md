# Cluster Identity (`EnvironmentConfig/cluster-identity`)

Nordri provisions a workspace-scoped `EnvironmentConfig` named `cluster-identity`
on every cluster it bootstraps. Downstream Crossplane compositions read it via
`function-environment-configs` so claim authors don't have to thread cluster
facts (storage class, ingress domain, environment kind) through every claim,
and templates don't have to branch on a `parameters.environment` ternary.

## The problem it solves

Without cluster identity, a single composition needs to know — at template
render time — *which* cluster it's running on so it can pick the right
StorageClass, ingress domain, and replica count. The historical pattern was a
required `parameters.environment` field on the claim plus per-step ternaries:

```yaml
storageClassName: {{ if eq .observed.composite.resource.spec.parameters.environment "gke" }}standard-rwo{{ else }}local-path{{ end }}
```

That works for two environments but doesn't scale: every composition repeats
the same branching, every claim repeats the same value, and every new
environment adds another `else if`. Worse, the same Git repo can't be applied
identically to homelab and GKE — claims have to be hydrated with environment
values per cluster.

Cluster identity inverts the relationship: the *cluster* declares its facts
once, and compositions read them.

## What's in cluster-identity

```yaml
apiVersion: apiextensions.crossplane.io/v1beta1
kind: EnvironmentConfig
metadata:
  name: cluster-identity
data:
  environment: homelab    # or "gke" — controls replica counts, etc.
  storageClass: local-path # or "standard-rwo" — used by all PVC-bound resources
  domain: homelab.local   # or "cmdbee.org" — base domain for ingress hosts
```

Per-environment definitions live in
`platform/fundamentals/manifests/cluster-identity-{homelab,gke}.yaml`. Each
overlay's `kustomization.yaml` includes only its own (the same file pattern as
`longhorn`/`garage` for homelab-only apps). The resource name is identical in
both — only the values differ — so compositions stay environment-agnostic.

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

1. Add the field to both `cluster-identity-homelab.yaml` and
   `cluster-identity-gke.yaml` under `data:`. Always extend both at once —
   they're parallel; missing keys cause "<no value>" surprises in templates.
2. Compositions that want it read it the same way:
   `{{ $identity.objectStoreEndpoint }}`.
3. Update this doc.

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
