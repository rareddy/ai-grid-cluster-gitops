# Keycloak token inspector

This tool runs on your computer. It starts a local OpenID Connect client and shows the ID token that Keycloak returns.

Run it:

```sh
tools/keycloak-token-inspector/run-local.sh
```

Open `http://localhost:8000`, then select `Sign in`. The script reads the Keycloak Route and client Secret from the current Kubernetes context. It also starts a temporary Kubernetes port-forward for the token exchange.

The callback URL is `http://localhost:8000/callback`. The Keycloak redirect-URI reconciler already allows it.

The page shows the decoded token claims and the raw ID token. It does not verify the token signature. Use it for manual testing only.

Select `Sign out` to end the Keycloak session and clear the local sign-in cookies.

Two incognito windows in the same browser share one cookie jar. To compare two users at the same time, use two separate browser profiles or two different browsers.

Run the tests:

```sh
node --test tools/keycloak-token-inspector/tests/server.test.js
```
