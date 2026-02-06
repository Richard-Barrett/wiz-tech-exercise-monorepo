#!/usr/bin/env bash
set -euo pipefail

ing=$(kubectl -n "$K8S_NAMESPACE" get ingress -o json)
name=$(echo "$ing" | jq -r '.items[0].metadata.name // empty')
[[ -n "$name" ]] || { echo "No ingress found in namespace $K8S_NAMESPACE"; exit 1; }

hostname=$(echo "$ing" | jq -r '.items[0].status.loadBalancer.ingress[0].hostname // empty')
ip=$(echo "$ing" | jq -r '.items[0].status.loadBalancer.ingress[0].ip // empty')

echo "Ingress: $name"
echo "LB Hostname: $hostname"
echo "LB IP: $ip"

[[ -n "$hostname" || -n "$ip" ]] || { echo "Ingress has no LoadBalancer address yet"; exit 1; }

echo "Ingress is fronted by a LoadBalancer."
