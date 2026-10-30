#!/usr/bin/env bash
# Point every Argo source for this repository at a fork, and its revision.
# Usage: scripts/set-tenant-repo.sh <repo-url> [revision]   (revision defaults to HEAD)
#        scripts/set-tenant-repo.sh --check
# The root ApplicationSet's generator names the current repository; every source
# naming it is rewritten, with the revision on the line after it.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
anchor=bootstrap/applicationset.yaml

current=$(awk '/repoURL:/ {print $2; exit}' "$anchor")
[[ -n $current ]] || { echo "error: no repoURL in $anchor" >&2; exit 1; }

sources() { grep -rlF --include='*.yaml' "repoURL: $current" . | sed 's|^\./||' | sort; }

check() {
  local bad=0 stray
  # Every source naming this repository carries a revision on the next line.
  while IFS= read -r f; do
    awk -v url="repoURL: $current" -v f="$f" '
      index($0, url) {want=1; next}
      want {if ($0 !~ /^[[:space:]]*(targetRevision|revision):[[:space:]]*[^[:space:]]+/) {print f": source without a revision after its repoURL"; bad=1}; want=0}
      END {exit bad}' "$f" || bad=1
  done < <(sources)
  # No other copy of this repository is named anywhere.
  stray=$(grep -rnE --include='*.yaml' 'repoURL:[[:space:]]*\S*(ai-grid-tenant|ai-grid-cluster-gitops)(\.git)?([[:space:]]|$)' . | grep -vF "repoURL: $current" || true)
  [[ -z $stray ]] || { echo "error: sources name another cluster GitOps repository:" >&2; echo "$stray" >&2; bad=1; }
  ((bad == 0)) && echo "ok: $(sources | wc -l) files point at $current"
  return "$bad"
}

if [[ ${1:-} == --check ]]; then
  check
  exit
fi

url=${1:?usage: $0 <repo-url> [revision] | --check}
revision=${2:-HEAD}
[[ $url =~ ^https://[^[:space:]]+\.git$ ]] || { echo "error: expected an https URL ending in .git, got $url" >&2; exit 1; }

while IFS= read -r f; do
  awk -v from="repoURL: $current" -v to="repoURL: $url" -v rev="$revision" '
    index($0, from) {sub(from, to); print; want=1; next}
    want && /^[[:space:]]*(targetRevision|revision):/ {sub(/(targetRevision|revision):.*/, ($0 ~ /targetRevision:/ ? "targetRevision: " : "revision: ") rev)}
    {want=0; print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done < <(sources)

current=$url
check
