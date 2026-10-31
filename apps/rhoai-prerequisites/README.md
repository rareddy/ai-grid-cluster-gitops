# RHOAI prerequisites

This app distributes the RHOAI installation prerequisites to every cluster
in the reserved `global` ACM cluster set:

- the protected `redhat-ai-grid` and `redhat-ods-operator` Namespaces;
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
them. No per-cluster `rosa`, `ocm`, or pull-secret command is required when a
managed cluster joins.

The global pull-secret policy is idempotent. It reads the current
`openshift-config/pull-secret`, preserves every existing credential, and
adds the hub-side entries it lacks: `quay.io/rhoai` from the Quay credential,
and any other registry the hub Secret holds. A bare `quay.io` entry in the hub
Secret is applied only as `quay.io/rhoai`, so the cluster's own `quay.io` login
stays. On ordinary control planes, updating that Secret triggers the normal
Machine Config Operator rollout to each node. HCP uses the separate mechanism
below.

## Hosted control planes

On clusters whose Infrastructure reports `controlPlaneTopology: External`,
configure the four digest-mirror mappings through the managed-service API
(for ROSA HCP, `rosa create image-mirror`). The image-mirror policy uses an
unnamed object template on these clusters: ACM evaluates unnamed templates in
inform mode, checking for an ImageDigestMirrorSet with all four mappings
without creating or updating it. It does not require the `quay-registry` name
or `NeverContactSource`, which the ROSA CLI does not expose. Missing mappings
remain NonCompliant. Ordinary clusters keep the named mirror enforcement.

Mirror pruning is disabled so policy transitions and removal preserve
service-managed and administrator-managed mirror resources. Pull-secret
policies still distribute registry credentials on both cluster types.

## Node credentials on hosted control planes

On HCP, the global pull-secret policy targets
`kube-system/additional-pull-secret` instead of `openshift-config/pull-secret`.
It merges the hub registry entries with any existing additional credentials,
scoping the Quay entry to `quay.io/rhoai`. HCCO merges the additional Secret
with the original HostedCluster pull secret; `global-pull-secret-syncer`
updates registry credentials on eligible workers and restarts kubelet when
credentials change. HCCO gives the original credentials precedence on exact
registry-key conflicts.

This requires HCP's global pull-secret feature and eligible workers. Verify
`kube-system/global-pull-secret-syncer` is Ready and covers all target workers.
On AWS Replace NodePools, eligible nodes have
`hypershift.openshift.io/nodepool-globalps-enabled=true`. See the
[HyperShift 4.22 procedure](https://github.com/openshift/hypershift/blob/release-4.22/docs/content/how-to/common/global-pull-secret.md).

Keep mirror credentials under their actual registry names. The image runtime
intentionally drops source credentials when redirecting to another registry
hostname; source aliases cannot replace node-level mirror authentication.
The catalog Secret is distributed unchanged from the hub credential input.
The policy preserves the original HostedCluster Secret and does not prune
previously managed pull Secrets.

## Temporary Grid EndpointSlice RBAC

Enabled remote sites with role ingress, inference or combined receive the same
namespace-scoped EndpointSlice Role and RoleBinding as the temporary hub
workaround in `apps/rhoai/hub/00-grid-endpointslice-rbac.yaml`. They let
`redhat-ods-applications/ai-gateway-operator` delegate the Grid leader-election
permissions it currently lacks. The hub remains owned by its existing Argo
manifest; this policy does not manage its Role or RoleBinding. Remove both
workarounds when the AI Gateway operator bundle supplies these permissions.

## Model publisher delegation

In namespaces opted in with `grid.opendatahub.io/allowed=true`, the existing
`grid-model-client-models` RoleBinding also grants the pinned
`redhat-ods-applications/odh-model-controller` ServiceAccount `post` on
`serving.opendatahub.io/models`. The controller must hold this permission to
delegate a model's publisher path to its generated identity; Kubernetes
otherwise rejects creation of the per-model Role. No additional verbs or
cluster-wide grant are needed. Remove this workaround when shipped operator
RBAC supplies the required namespace permissions.

## Shared Limitador Redis

`apps/limitador-redis` owns the Redis instance and its local Limitador storage
configuration on `local-cluster`. On enabled remote ingress and combined sites, the
`rhoai-limitador-redis` Policy creates the `limitador-redis` namespace needed
for the Submariner `ServiceImport`, the `kuadrant-system/limitador-redis`
Secret, and the `Limitador/limitador` Redis storage reference. Remote
Limitadors therefore use:

```text
redis://limitador-redis-master.limitador-redis.svc.clusterset.local:6379
```

The local Redis NetworkPolicy permits Submariner GlobalNet traffic
(`242.0.0.0/8`). The policy excludes inference-only and unselected clusters, which do not run
MaaS. It also excludes `local-cluster` and dedicated MaaS-home sites because
their local Applications own Redis and the Limitador storage configuration.

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
