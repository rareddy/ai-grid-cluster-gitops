# RHOAI prerequisites

This app distributes the RHOAI installation prerequisites to every cluster
in the reserved `global` ACM cluster set:

- the `redhat-ai-grid` and model Namespaces on all registered clusters;
- `redhat-ods-operator` only on enabled Grid sites with an ingress, inference or combined role;
- the same `ImageDigestMirrorSet` used by the hub;
- the `openshift-marketplace/rhoai-catalog-pull-secret` required to pull the
  RHOAI catalog image;
- merged `openshift-config/pull-secret` entries for `quay.io/rhoai`, required
  for mirrored operator-bundle pulls, and for every other registry the hub
  Secret holds, such as `registry.stage.redhat.io` for the
  `registry.redhat.io/rhaii*` mirrors that model images pull through.
- the remote-only Limitador Redis configuration that shares MaaS rate-limit
  counters through the Submariner service import.
- the catalog ServiceAccount's `imagePullSecrets` wiring is managed by
  `apps/rhoai/catalog`; OLM does not update an already-created catalog
  ServiceAccount when `CatalogSource.spec.secrets` changes.

The Quay credentials are never stored in Git. The pull-secret policy uses an
ACM hub template to check for `rhoai-prerequisites/rhoai-quay-pull-secret`
before rendering the remote Secret. Until that hub Secret exists and contains
a non-empty `.dockerconfigjson` key, the pull-secret policy has no remote
object templates and makes no changes on managed clusters. The image mirror is
still distributed because it does not contain credentials.

## Clean-cluster flow

`bootstrap.sh` seeds only the hub-side credential Secret. The root
ApplicationSet then discovers this app, ACM applies the prerequisites to every
cluster in the `global` cluster set, and the RHOAI ApplicationSet deploys after
them. Conventional clusters receive their mirror directly. ROSA HCP clusters require
service-managed mirrors before import, as described below. Do not add Grid role
labels until prerequisites and worker credentials are verified.

## Hosted control planes

On `Infrastructure/cluster.status.controlPlaneTopology=External`, configure
digest mirrors through the supported ROSA/HostedCluster management path, not
guest `ImageDigestMirrorSet` writes. The mirror policy observes an unnamed
service-managed object containing all four required mappings; it does not
change or prune that object. Missing mappings remain NonCompliant. The current
check requires all four mappings in one IDMS. ROSA's mirror CLI does not expose
`NeverContactSource`; this check does not assert fallback-policy parity.
Conventional clusters keep named `quay-registry` enforcement with
`NeverContactSource`. Mirror pruning is disabled to preserve service/admin
configuration on policy transitions or removal.

The existing credential policy targets `kube-system/additional-pull-secret` on
HCP and `openshift-config/pull-secret` on conventional clusters, preserving
existing entries. Quay credentials stay scoped to `quay.io/rhoai`. HCP's managed
global-pull-secret syncer must be available and enabled for every worker node
pool; Secret existence alone is insufficient. Verify node credential delivery
before enabling RHOAI. Credential rollout can restart kubelet.

The hub Secret must provide access to `quay.io/rhoai` and, for pre-release
model images, `registry.stage.redhat.io`. Do not print its credential data.
See [the HCP onboarding checklist](../../docs/acm/cluster-onboarding/README.md#rosa-hcp-preflight).

## Shared Limitador Redis

`apps/limitador-redis` owns the Redis instance and its local Limitador storage
configuration on `local-cluster`. On enabled ingress/combined sites other than `local-cluster` and the
MaaS-home site, the `rhoai-limitador-redis` Policy creates the `limitador-redis` namespace needed
for the Submariner `ServiceImport`, the `kuadrant-system/limitador-redis`
Secret, and the `Limitador/limitador` Redis storage reference. Remote
Limitadors therefore use:

```text
redis://limitador-redis-master.limitador-redis.svc.clusterset.local:6379
```

The local Redis NetworkPolicy permits Submariner GlobalNet traffic
(`242.0.0.0/8`). The policy intentionally excludes `local-cluster` so the
existing local Argo Application remains the sole owner of the Redis and local
Limitador storage resources. It also excludes inference-only and unlabelled
clusters, and waits for the Kuadrant namespace and Limitador CRD before
creating the Secret or Limitador storage reference.

## Create the hub Secret

Set `RHOAI_QUAY_PULL_SECRET` to the base64-encoded `username:password` value
that can pull both the RHOAI catalog and operator-bundle repositories, then
run:

```sh
export HUB_CONTEXT='<hub-kubeconfig-context>'
read -s RHOAI_QUAY_PULL_SECRET
export RHOAI_QUAY_PULL_SECRET

apps/rhoai-prerequisites/create-hub-secret.sh
```

ACM watches the hub Secret and reconciles the policy after it is created or
updated. Removing the hub Secret does not delete an already-created pull Secret
on a managed cluster; this avoids accidentally removing credentials because of
a temporary hub-side Secret outage.

## Verify

Use metadata-only commands so the credential is not displayed:

```sh
kubectl --context "$HUB_CONTEXT" -n rhoai-prerequisites get secret rhoai-quay-pull-secret \
  -o custom-columns='NAME:.metadata.name,TYPE:.type'
kubectl --context "$HUB_CONTEXT" -n rhoai-prerequisites get placementdecisions
kubectl --context "$HUB_CONTEXT" get policies -n rhoai-prerequisites
kubectl --context "$SPOKE_CONTEXT" -n openshift-config get secret pull-secret \
  -o custom-columns='NAME:.metadata.name,TYPE:.type'
kubectl --context "$SPOKE_CONTEXT" -n rhoai-prerequisites get configurationpolicy \
  rhoai-global-pull-secret
kubectl --context "$SPOKE_CONTEXT" -n limitador-redis get serviceimport \
  limitador-redis-master
kubectl --context "$SPOKE_CONTEXT" -n kuadrant-system get limitador limitador \
  -o jsonpath='{.spec.storage.redis.configSecretRef.name}{"\n"}'
```
