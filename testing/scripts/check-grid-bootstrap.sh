#!/usr/bin/env bash
# Read-only readiness checks for this repository's bootstrap.
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: bash check-grid-bootstrap.sh [--context NAME] [--stage import|stack]
       [--profile auto|combined|dedicated-hub] [--wait SECONDS] [--repo URL]

Requires oc (or kubectl) and jq. Uses the current kubeconfig/context by default.
import: foundation ready to import spokes; does not require every workload.
stack:  strict Argo/workload readiness after site selection and secret seeding.
--repo: expected Git source URL (default: local bootstrap/applicationset.yaml).
--wait: poll every 15 seconds for up to SECONDS (default: one check).
Exit: 0 ready for selected stage, 1 not ready, 2 invalid arguments/setup.
No writes to Kubernetes, no Secret contents displayed, no inference requests.
EOF
}

stage=import
profile=auto
context=''
wait_seconds=0
repo=''
namespace=openshift-gitops
while (($#)); do
  case "$1" in
    --context|--stage|--profile|--wait|--repo)
      (($# >= 2)) || { usage >&2; exit 2; }
      case "$1" in
        --context) context=$2 ;;
        --repo) repo=$2 ;;
        --stage) stage=$2 ;;
        --profile) profile=$2 ;;
        --wait) wait_seconds=$2 ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ $stage == import || $stage == stack ]] || { usage >&2; exit 2; }
[[ $profile == auto || $profile == combined || $profile == dedicated-hub ]] || { usage >&2; exit 2; }
[[ $wait_seconds =~ ^[0-9]+$ ]] || { usage >&2; exit 2; }
if [[ -z $repo ]]; then
  repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
  anchor="$repository_root/bootstrap/applicationset.yaml"
  [[ -r $anchor ]] || { echo 'Cannot find bootstrap/applicationset.yaml; pass --repo URL.' >&2; exit 2; }
  repo=$(awk '/repoURL:/ {print $2; exit}' "$anchor")
fi
repo=${repo%.git}
[[ -n $repo ]] || { echo 'Expected repository URL is empty; pass --repo URL.' >&2; exit 2; }
command -v jq >/dev/null || { echo 'Install jq first.' >&2; exit 2; }
if command -v oc >/dev/null; then cli=oc
elif command -v kubectl >/dev/null; then cli=kubectl
else echo 'Install oc or kubectl first.' >&2; exit 2
fi
if [[ -z $context ]]; then
  context=$("$cli" config current-context) || { echo 'Select a kubeconfig context.' >&2; exit 2; }
fi
[[ -n $context ]] || { echo 'Select a kubeconfig context.' >&2; exit 2; }
k() { "$cli" --context "$context" --request-timeout=10s "$@"; }
ok() { printf 'OK    %s\n' "$*"; }
pending() { printf 'WAIT  %s\n' "$*"; failures=$((failures + 1)); }
check() {
  local description=$1 resource=$2 ns=$3 name=$4 filter=$5 data
  local args=(get "$resource")
  [[ -z $ns ]] || args+=(-n "$ns")
  [[ -z $name ]] || args+=("$name")
  if ! data=$(k "${args[@]}" -o json 2>/dev/null); then
    pending "$description (missing, inaccessible, or API unavailable)"
  elif jq -e "$filter" >/dev/null <<<"$data"; then
    ok "$description"
  else
    pending "$description"
  fi
}
ready='any(.status.conditions[]?; .type == "Available" and .status == "True")'
deployment_ready='(.status.observedGeneration // 0) >= .metadata.generation and (.spec.replicas // 1) > 0 and (.status.updatedReplicas // 0) == (.spec.replicas // 1) and (.status.availableReplicas // 0) == (.spec.replicas // 1)'

run_checks() {
  local root apps selected detected app status errors
  failures=0
  printf '\nChecking stage=%s context=%s\n' "$stage" "$context"
  if ! root=$(k -n "$namespace" get applicationsets.argoproj.io apps -o json 2>/dev/null); then
    pending 'root ApplicationSet apps is missing or inaccessible; verify bootstrap and cluster access'
    return 1
  fi
  if ! jq -e --arg repo "$repo" '
    [.spec.generators[]?.git.repoURL // empty] as $urls |
    ($urls | length) > 0 and all($urls[]; rtrimstr(".git") == $repo)
  ' >/dev/null <<<"$root"; then
    pending "root source differs from $repo.git; fix Git source before waiting"
    return 1
  fi
  ok 'root ApplicationSet points at the requested fork'
  if jq -e 'any(.status.conditions[]?; .status == "True" and (.type | endswith("Error")))' >/dev/null <<<"$root"; then
    pending 'root ApplicationSet reports an error; inspect its Conditions in Argo'
  fi
  detected=combined
  if jq -e 'any(.spec.generators[]?.git.files[]?; .path == "apps/maas-home/application.yaml" and .exclude != true)' >/dev/null <<<"$root"; then
    detected=dedicated-hub
  fi
  selected=$profile
  [[ $selected != auto ]] || selected=$detected
  printf 'INFO  bootstrap profile=%s\n' "$selected"
  if [[ $selected != "$detected" ]]; then pending "requested profile disagrees with root selection ($detected)"; fi

  if ! apps=$(k -n "$namespace" get applications.argoproj.io -o json 2>/dev/null); then
    pending 'cannot list Argo Applications'
    return 1
  fi
  local required=(gitops-config ai-grid-spokes rhoai-prerequisites acm-models)
  [[ $selected != dedicated-hub ]] || required+=(argo-registration)
  if [[ $stage == stack ]]; then
    if [[ $selected == combined ]]; then
      required=(acm acm-models ai-grid-o11y ai-grid-policies ai-grid-spokes
        cluster-config console external-secrets gitops-config grid-bootstrap
        keycloak limitador-redis maas-db odf rhoai rhoai-prerequisites)
    else
      required=(acm acm-models ai-grid-policies ai-grid-spokes argo-registration
        cert-manager gitops-config grid-bootstrap maas-home rhoai rhoai-prerequisites)
    fi
  fi
  app_ready() {
    local name=$1
    status=$(jq -r --arg name "$name" '.items[] | select(.metadata.name == $name) | "\(.status.sync.status // "Unknown")/\(.status.health.status // "Unknown")"' <<<"$apps")
    errors=$(jq -r --arg name "$name" '[.items[] | select(.metadata.name == $name) | .status.conditions[]? | select(.type | endswith("Error"))] | length' <<<"$apps")
    if [[ $status == Synced/Healthy && $errors == 0 ]]; then ok "Application $name $status"
    else pending "Application $name ${status:-MISSING}, error conditions=$errors"
    fi
  }
  for app in "${required[@]}"; do app_ready "$app"; done
  check 'Argo application controller available' statefulsets.apps "$namespace" openshift-gitops-application-controller \
    '(.status.observedGeneration // 0) >= .metadata.generation and (.spec.replicas // 1) > 0 and (.status.readyReplicas // 0) == (.spec.replicas // 1) and (.status.currentRevision // "") != "" and .status.currentRevision == .status.updateRevision'
  check 'Argo ApplicationSet controller available' deployments.apps "$namespace" openshift-gitops-applicationset-controller "$deployment_ready"
  check 'ACM MultiClusterHub Running' multiclusterhubs.operator.open-cluster-management.io open-cluster-management '' \
    '(.items | length) > 0 and all(.items[]; .status.phase == "Running")'
  check 'hub ManagedCluster joined and available' managedclusters.cluster.open-cluster-management.io '' local-cluster \
    'any(.status.conditions[]?; .type == "ManagedClusterJoined" and .status == "True") and any(.status.conditions[]?; .type == "ManagedClusterConditionAvailable" and .status == "True")'
  check 'global cluster-set binding in openshift-gitops' managedclustersetbindings.cluster.open-cluster-management.io "$namespace" global '.spec.clusterSet == "global"'
  for addon in governance-policy-framework config-policy-controller; do
    check "hub $addon add-on available" managedclusteraddons.addon.open-cluster-management.io local-cluster "$addon" "$ready"
  done
  # Request resource names only: never print or persist Secret data.
  if k -n rhoai-prerequisites get secret rhoai-quay-pull-secret -o name >/dev/null 2>&1; then
    ok 'hub registry pull Secret exists (presence only)'
  else pending 'hub registry pull Secret missing; bootstrap credential seeding may have failed'
  fi

  if [[ $stage == stack ]]; then
    while IFS= read -r app; do
      [[ -z $app ]] || app_ready "$app"
    done < <(jq -r '.items[].metadata.name | select(test("^(rhoai-|grid-provider-gateway-|maas-db-|acm-models-|acm-submariner-|cluster-config-|maas-home-)"))' <<<"$apps")
    check 'at least one selected Grid site' managedclusters.cluster.open-cluster-management.io '' '' \
      'any(.items[]; .metadata.labels["ai-grid/enabled"] == "true" and (.metadata.labels["ai-grid/role"] | IN("ingress", "inference", "combined")))'
    check 'Grid CA issuer Ready' issuers.cert-manager.io redhat-ai-grid grid-ca \
      'any(.status.conditions[]?; .type == "Ready" and .status == "True")'
    check 'Grid bootstrap state ConfigMap exists and is immutable' configmaps redhat-ai-grid grid-bootstrap-state \
      '.immutable == true and (.data | type == "object" and length > 0)'
    if [[ $selected == combined ]]; then
      check 'combined hub selected with the combined role' managedclusters.cluster.open-cluster-management.io '' local-cluster \
        '.metadata.labels["ai-grid/enabled"] == "true" and .metadata.labels["ai-grid/role"] == "combined"'
      for pattern in '^rhoai-local-cluster-[0-9a-f]{8}$' '^grid-provider-gateway-local-cluster' '^maas-db-local-cluster$'; do
        if jq -e --arg p "$pattern" 'any(.items[]; .metadata.name | test($p))' >/dev/null <<<"$apps"; then
          ok "generated Application exists: $pattern"
        else pending "generated Application missing: $pattern"
        fi
      done
      check 'MaaS primary database healthy' clusters.postgresql.cnpg.io maas-db maas-db \
        '.status.phase == "Cluster in healthy state"'
      check 'Keycloak Deployment available' deployments.apps maas-db keycloak "$deployment_ready"
      check 'Grid operator Deployment available' deployments.apps redhat-ai-grid grid-operator "$deployment_ready"
      check 'GridNetwork Active with Local membership' gridnetworks.grid.praxis.fast '' grid \
        '.status.phase == "Active" and .spec.membership.mode == "Local" and (.spec.gridId // "" | length) > 0'
      check 'KServe and AIGrid components Ready' datascienceclusters.datasciencecluster.opendatahub.io '' default-dsc \
        'any(.status.conditions[]?; .type == "KserveReady" and .status == "True") and any(.status.conditions[]?; .type == "AIGridReady" and .status == "True")'
      for secret in ai-grid-provider-console-oauth ai-grid-backend-keycloak ai-grid-backend-git; do
        if k -n ai-grid-provider-console get secret "$secret" -o name >/dev/null 2>&1; then
          ok "console Secret $secret exists (presence only)"
        else pending "console Secret $secret missing; run documented console/create-secrets.sh after Route and Keycloak are ready"
        fi
      done
      check 'console Deployment available' deployments.apps ai-grid-provider-console ai-grid-provider-console "$deployment_ready"
    else
      check 'a MaaS home is selected' managedclusters.cluster.open-cluster-management.io '' '' \
        '([.items[] | select(.metadata.labels["ai-grid/maas-home"] == "true")] | length) == 1'
      echo 'INFO  Dedicated profile omits console, Submariner and observability; inspect site runtime separately.'
    fi
  fi
  if ((failures == 0)); then
    printf '\nREADY for stage=%s. ' "$stage"
    if [[ $stage == import ]]; then
      echo 'You can proceed to spoke import; Grid workloads may still be pending.'
    else echo 'Argo/install checks passed; run tenant inference and cross-site validation next.'
    fi
    return 0
  fi
  printf '\nNOT READY: %s check(s) pending.\n' "$failures"
  return 1
}

deadline=$((SECONDS + 10#$wait_seconds))
while true; do
  if run_checks; then exit 0; fi
  if ((SECONDS >= deadline)); then exit 1; fi
  remaining=$((deadline - SECONDS))
  delay=15
  ((remaining >= delay)) || delay=$remaining
  sleep "$delay"
done
