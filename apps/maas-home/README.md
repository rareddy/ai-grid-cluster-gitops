# MaaS home

A dedicated hub runs no MaaS state. One site holds it instead: the cluster
labelled `ai-grid/maas-home=true`.

```sh
oc label managedcluster site-a ai-grid/maas-home=true
```

The `maas-home` ApplicationSet installs these on it, reusing each app's
manifests:

| Component | From |
|---|---|
| External Secrets Operator | `apps/external-secrets/manifests` |
| `maas-db` primary | `apps/maas-db/local-cluster`, without its ServiceExport |
| Keycloak | `apps/keycloak`, without the hub's public-URL Policy |
| Limitador's Redis | `apps/limitador-redis/manifests`, without its ServiceExport |

The hub Policies here give the home its Keycloak public URL and `maas-api`'s
database connection, both read from the home's own Route and Secrets. The
tenant Policy (`apps/rhoai/hub`) finds Keycloak on the home through its
console-URL cluster claim.

The label selects the home through Argo CD's cluster Secret, which ACM never
removes a label from, and the ApplicationSet preserves what it installed, so
removing the label deletes nothing. Moving the home means moving its database.

Label one cluster, normally also an AI Grid site with role `ingress` or
`combined`. Other ingress sites don't get a read replica or database
credentials yet: both are copied from Secrets on the hub, where a dedicated
hub has none.

## End-user portal on the MaaS gateway

On the MaaS home, when its Grid role is `ingress` or `combined`,
`hub/06-portal-gateway.yaml` adds a browser entry point to the existing
`maas-default-gateway`. The RHOAI dashboard keeps its OpenShift login.
End users use the new entry point and sign in through the Keycloak issuer
already declared in their AITenant.

The integration adapts the tenant portal example from
[`lphiri/maas-portal-integration-poc`](https://github.com/lphiri/maas-portal-integration-poc/tree/f163e026e9b5f418652043f1a284c7398cd1ab14/deploy/maas-portal).
It reuses the existing portal Deployment and shared BFF. A dedicated OIDC
session proxy uses the same image as the installed dashboard auth proxy;
route AuthPolicies forward the tenant access token to the portal. API and
model routes retain their existing authentication and quotas. Only portal
and login routes bypass inference payload processing and token limits.

An OpenShift reencrypt Route named `maas-portal` in `openshift-ingress`
provides a hostname under the cluster's ingress domain. Browser TLS uses
the existing ingress wildcard certificate; the route trusts the service CA
for its connection to the MaaS gateway. The gateway verifies the portal
backend's service certificate. The Keycloak issuer must be trusted by the
proxy image's system CA store; private issuers require an explicit provider
CA configuration before enabling this integration.

### Prerequisites and callback registration

The ingress MaaS home must already have RHOAI, the portal, the MaaS gateway,
External Secrets and the custom Keycloak configuration. The policy copies
only `KEYCLOAK_CLIENT_ID` and `KEYCLOAK_CLIENT_SECRET` from the existing
`maas-db/keycloak-secrets` into a local proxy Secret; these must match the
AITenant client and its current Keycloak credentials. External Secrets
generates a separate, retained session-cookie Secret once. No credentials
are committed or displayed by the verification commands below.

After syncing `rhoai` and `maas-home`, obtain the assigned hostname:

```sh
INGRESS_CONTEXT='<ingress-context>'
oc get route maas-portal --context="$INGRESS_CONTEXT" -n openshift-ingress \
  -o jsonpath='https://{.spec.host}/oauth2/callback{"\n"}'
```

In Keycloak, select the AITenant's broker realm (currently `saas`), then its
client (currently `tenant-demo`). Keep Standard flow enabled and **append**
the printed exact URL to Valid redirect URIs. Preserve existing redirects,
mappers, organizations, IdPs and users. This callback change does not require
a Keycloak restart. The existing forced-import startup behavior is a separate
known risk: do not restart Keycloak until realm preservation is addressed.

Open the tenant portal at the URL printed by:

```sh
oc get route maas-portal --context="$INGRESS_CONTEXT" -n openshift-ingress \
  -o jsonpath='https://{.spec.host}/maas-portal/?devFeatureFlags=grid=true{"\n"}'
```

### Operator verification

Check the two new `maas-home-portal-*` Policies are Compliant, the Route is
Admitted, `maas-consumer-auth-proxy` has a ready replica, and the
`maas-consumer-ui`/`maas-consumer-oauth2` HTTPRoutes and AuthPolicies are
Accepted and Enforced. Both routes must attach to `maas-default-gateway`.
No objects are delivered to inference-only sites or a management-only hub.

Verify browser login redirects to Keycloak, assets and deep links load, and
the user's subscription appears before creating a short-lived key. Check an
invalid explicit bearer receives 401 even with a browser session cookie.
The inherited example refreshes access tokens through session checks, but
does not propagate refreshed session cookies from those checks back to the
browser; verify behavior after token expiry as well as initial login.

Envoy route IDs and four inference filter names are version-sensitive. The
prepared integration matches the current gateway configuration; check them
after gateway upgrades. The new ACM policies preserve their created objects
when removed (`pruneObjectBehavior: None`); removal is not an automatic
rollback. For rollback, stop policy enforcement and explicitly retire only
the new consumer Route, proxy and route-specific policies after review.
