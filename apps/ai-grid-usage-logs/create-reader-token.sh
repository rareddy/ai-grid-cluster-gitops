#!/usr/bin/env bash

set -Eeuo pipefail

sa_namespace="${SA_NAMESPACE:-redhat-ods-monitoring}"
sa_name="${SA_NAME:-usage-logs-reader}"
namespace="${NAMESPACE:-ai-grid-policies}"
secret_name="${SECRET_NAME:-usage-logs-hub-read-credential}"
duration="${TOKEN_DURATION:-8760h}"
context="${HUB_CONTEXT:-}"

usage() {
  cat <<'EOF'
Mint the hub usage-log reader token and store it in the Secret the
ai-grid-usage-logs spoke Policy ships to every selected site's read
consumer.

The chart cannot create this: a ServiceAccount token is not a declarative
object. ACM reads the Secret with fromSecret and delivers $ocm_encrypted
ciphertext, so the token itself never appears in a managed cluster's manifest.

The identity is read-only -- `get` on the infrastructure tenant, no `create` --
so a leaked token exposes usage records but cannot corrupt them.

Re-running rotates the token. The Policy re-resolves the Secret and each site
picks up the new value, so rotation is the same operation as creation.

Optional environment:
  HUB_CONTEXT     Hub kubeconfig context.
  SA_NAMESPACE    ServiceAccount namespace; defaults to redhat-ods-monitoring,
                  where apps/ai-grid-o11y puts the read identity.
  SA_NAME         ServiceAccount name; defaults to usage-logs-reader.
  NAMESPACE       Secret namespace; defaults to ai-grid-policies, which is
                  spokePolicy.namespace.
  SECRET_NAME     Secret name; defaults to usage-logs-hub-read-credential, which is
                  spokePolicy.readCredential.credentialSecretName.
  TOKEN_DURATION  Token lifetime; defaults to 8760h (one year). The cluster's
                  --service-account-max-token-expiration may cap it; the
                  Verify section of the README prints what was actually issued.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

for required_command in kubectl base64; do
  command -v "$required_command" >/dev/null 2>&1 || die "required command not found: $required_command"
done

kubectl_args=()
if [ -n "$context" ]; then
  kubectl_args+=(--context "$context")
fi

# The ServiceAccount belongs to apps/ai-grid-o11y, which owns the store. A
# token minted before that app has synced would fail with an API error rather
# than a reason, so say which Application has to run first.
kubectl "${kubectl_args[@]}" get serviceaccount "$sa_name" -n "$sa_namespace" >/dev/null 2>&1 ||
  die "serviceaccount $sa_namespace/$sa_name not found: let the ai-grid-o11y Application sync first"

token="$(kubectl "${kubectl_args[@]}" create token "$sa_name" \
  --namespace "$sa_namespace" --duration="$duration")"
# Never write an empty or truncated credential: the Policy would ship it to
# every site and each consumer would fail to authenticate with no clear cause.
[ -n "$token" ] || die "failed to create a token for $sa_namespace/$sa_name"
case "$token" in
  *.*.*) ;;
  *) die "token for $sa_namespace/$sa_name is not a JWT; refusing to write it" ;;
esac

# Declarative, so it cannot collide with Argo CD creating the same namespace
# between a check and a create on a fresh hub.
kubectl "${kubectl_args[@]}" create namespace "$namespace" --dry-run=client -o yaml |
  kubectl "${kubectl_args[@]}" apply -f -

token_b64="$(printf '%s' "$token" | base64 -w0)"

kubectl "${kubectl_args[@]}" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $secret_name
  namespace: $namespace
type: Opaque
data:
  token: $token_b64
EOF

printf 'Created or updated %s/%s from %s/%s.\n' "$namespace" "$secret_name" "$sa_namespace" "$sa_name"
