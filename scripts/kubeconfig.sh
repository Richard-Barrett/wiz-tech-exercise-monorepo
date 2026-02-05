#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT_DIR/infra/terraform"

CLUSTER_NAME="$(cd "$TF_DIR" && terraform output -raw eks_cluster_name)"
REGION="$(cd "$TF_DIR" && terraform output -raw aws_region)"

echo "Configuring kubeconfig for cluster: $CLUSTER_NAME ($REGION)"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

kubectl get nodes
