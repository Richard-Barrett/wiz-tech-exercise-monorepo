#!/usr/bin/env bash
set -euo pipefail

# Tries to find a ClusterRoleBinding granting cluster-admin to the ServiceAccount.
# Assumes SA name is wizapp-sa; adjust if yours differs.
SA_NAME="wizapp-sa"

bindings=$(kubectl get clusterrolebinding -o json)
match=$(echo "$bindings" | jq -r '
  .items[]
  | select(.roleRef.kind=="ClusterRole" and .roleRef.name=="cluster-admin")
  | select(any(.subjects[]?; .kind=="ServiceAccount" and .name=="'"$SA_NAME"'" and .namespace=="'"$K8S_NAMESPACE"'"))
  | .metadata.name
' | head -n1)

if [[ -z "$match" ]]; then
  echo "No clusterrolebinding found that grants cluster-admin to ${K8S_NAMESPACE}/${SA_NAME}"
  exit 1
fi

echo "Found cluster-admin binding: $match"
