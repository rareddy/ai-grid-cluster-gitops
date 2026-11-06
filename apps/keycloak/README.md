# Keycloak

This app migrates the Keycloak component from
`lphiri/maas-portal-integration-poc` into a dedicated Argo CD Application. The
bootstrap ApplicationSet discovers `apps/keycloak/application.yaml` automatically.

## Install profiles

The app has two profiles. Each profile is a kustomize overlay.

- `overlays/default` installs Keycloak and the example realms. It adds the
  `grid-tenant-1-idp` and `grid-tenant-2-idp` realms, the example identity
  providers and organizations in the `saas` realm, and the two example signing
  keys. This is the default.
- `overlays/core` installs Keycloak and only the `saas` broker realm. The core
  realm has the broker client and its signing key. It has no identity
  providers, organizations, or example tenants.

The `saas` broker mints `org_id` from the identity provider binding. The token
carries flat `org_id`, `org_name`, and `roles` claims and plain `groups`.

To install only the core realm, set the keycloak Application source path to
`apps/keycloak/overlays/core`. The default path is
`apps/keycloak/overlays/default`.

## Direct install

For a cluster without Argo CD, run:

```sh
apps/keycloak/install.sh
```

Use `--render` to print the manifests without applying them. The script uses
the default profile and installs in the `maas-db` namespace. It reads the Route
host assigned by OpenShift and creates the `keycloak-public-url` ConfigMap. It
does not install or use Argo CD or ACM. It still requires the CloudNativePG
cluster, External Secrets, and cert-manager to be installed.
The direct installer creates namespace `maas-db` when it does not exist.

## Topology

- Keycloak runs in `maas-db` on the GitOps hub cluster, while remaining a
  separate Argo CD Application from `maas-db`.
- The app reuses the healthy `maas-db` CloudNativePG cluster. Its
  `DatabaseRole` and `Database` resources create a dedicated `keycloak` role
  and database without sharing credentials with the API database user.
- Keycloak connects to `maas-db-rw` with TLS and verifies the server against
  the existing `maas-db-ca` Secret.
- The default install imports the example realms and the core `saas` broker
  realm when they do not exist. The `core` overlay excludes the examples.
- The upstream example `AITenant` resource is intentionally not applied by this
  app; the tenant-facing application should own its consumer configuration.

The app intentionally does not create the `maas-db` namespace or a second
PostgreSQL cluster. It can initially report missing namespace or resource
errors until the `maas-db` Application has created the namespace and installed
the CloudNativePG CRDs. Its retry policy refreshes and retries automatically.

## Generated Secrets

Git does not store Keycloak, client, broker, test-user, or database secret
values. The app depends on the `external-secrets` Application and uses Password
generators to create two Secrets in `maas-db`:

- `keycloak-db` holds the dedicated PostgreSQL role credentials consumed by
  CloudNativePG and Keycloak.
- `keycloak-secrets` holds Keycloak bootstrap, client, broker, and test-user
  values.

The `ExternalSecret` resources use `refreshPolicy: CreatedOnce` and
`refreshInterval: 0s`, so each value is generated once and is not rotated by
the controller. Password generators are stateless, so any refresh would replace
every generated value: the bootstrap admin's password, which Keycloak applies
only when it first creates the master realm, would stop matching the admin, and
a realm that isn't re-imported on start would keep the old client and broker
secrets. `keycloak-secrets` uses `mergePolicy: Merge`, so
template keys and the generator-backed `dataFrom` keys coexist. To change its
template on a running cluster, delete Secret `keycloak-secrets` once so it's
generated again. Their deletion policy retains the generated Secrets if the
Keycloak app is removed. The Keycloak app may initially report missing resource
errors until the External Secrets CRDs are installed; its retry policy
refreshes and retries automatically.

The Keycloak admin username and non-secret client configuration are declared in
the `keycloak-secrets` ExternalSecret template. To retrieve a generated value
for operational use, read it from the corresponding Kubernetes Secret through
the cluster's approved secret-access process.

## Dynamic Public URL

The `keycloak` Route omits `spec.host`, so OpenShift assigns the public host
from the cluster's ingress domain. An ACM Policy uses a hub-template Route
lookup to render that assigned host into the `keycloak-public-url` ConfigMap on
the hub, the one cluster the dedicated `keycloak-public-url-clusters`
Placement selects (ACM's `local-cluster=true` label). The Deployment consumes the ConfigMap for
`KEYCLOAK_PUBLIC_URL` and `KC_HOSTNAME`, so no cluster-specific URL is stored
in Git.

The Placement selects the existing `global` ManagedClusterSet. The `maas-db`
Application already binds that cluster set in the shared `maas-db` namespace,
which this app depends on for its database.

Removing an explicit host from an existing Route can change the assigned public
URL. Plan the corresponding Keycloak realm and client update before relying on
the new issuer because Keycloak skips imports for realms that already exist in
PostgreSQL.

## Consumer Portal Redirects

The `keycloak-redirect-uris` CronJob keeps the `tenant-demo` client aligned
with active AI Grid ingress sites. Every five minutes it lists
`ManagedClusters` labelled `ai-grid/enabled=true` and
`ai-grid/role in (ingress,combined)`, derives each cluster's apps domain from
its `consoleurl.cluster.open-cluster-management.io` claim, and sets the client's
redirect URIs to:

- `https://maas.<cluster-apps-domain>/oauth2/callback` for each site.
- `http://localhost:8000/callback` for the browserless smoke test.

The job replaces the complete redirect list, so removing a cluster's ingress or
combined role removes its callback on the next run. A Keycloak restart does not
re-import an existing realm, so the CronJob continues to maintain the live
redirect list.

The updater authenticates with the realm-scoped `keycloak-redirect-uris`
service account, whose generated client secret is stored in the dedicated
`keycloak-redirect-uris-secret` Secret. It has only the `saas` realm's client
view and manage permissions.

## Stable Signing Keys

Each realm uses a dedicated cert-manager-managed RSA signing key. cert-manager
creates a JKS keystore for each realm and reuses the same private key across
certificate renewals. The realm import references the mounted JKS file and a
fixed `kid`, so Keycloak restarts do not invalidate previously issued tokens.

The signing keystores are generated in the `maas-db` namespace and are not
stored in Git. The JKS password is generated by External Secrets and is shared
by the three realm-specific keystores.

Realm imports replace `${KEYCLOAK_PUBLIC_URL}` with the value from the
public-URL ConfigMap and the broker/client/test-user keys with values from the
Keycloak Secret. Keycloak starts with `kc.sh import --override false`, so it
skips a realm that already exists. Runtime changes in an existing realm survive
a restart. Use a planned Keycloak export/import to apply later edits from Git
to an existing realm.

## Validation

```sh
kubectl get applications.argoproj.io -n openshift-gitops
kubectl get externalsecrets -n maas-db
kubectl get databaseroles,databases -n maas-db
kubectl rollout status deployment/keycloak -n maas-db
kubectl get route keycloak -n maas-db
kubectl get configmap keycloak-public-url -n maas-db
```

The Keycloak database inherits the availability and storage characteristics of
the existing `maas-db` CloudNativePG cluster. Database backups remain the
responsibility of that shared database app.

The stable realm signing keys depend on the cluster-wide cert-manager
installation.
