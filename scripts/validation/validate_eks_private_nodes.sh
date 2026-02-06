#!/usr/bin/env bash
set -euo pipefail

# Private nodes: instances should not have public IPs.
# We map node -> providerID -> instanceId and check PublicIpAddress is null.

nodes=$(kubectl get nodes -o json)
instance_ids=$(echo "$nodes" | jq -r '
  .items[].spec.providerID
  | select(startswith("aws:///"))
  | split("/")[-1]
' | sort -u)

[[ -n "$instance_ids" ]] || { echo "No AWS node instance IDs found"; exit 1; }

echo "Node instance IDs:"
echo "$instance_ids"

for iid in $instance_ids; do
  pub=$(aws ec2 describe-instances --instance-ids "$iid" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
  echo "Instance $iid PublicIp: $pub"
  if [[ "$pub" != "None" ]]; then
    echo "Node has a public IP. Cluster is not private."
    exit 1
  fi
done

echo "All nodes have no public IPs (private subnet assumption satisfied)."
