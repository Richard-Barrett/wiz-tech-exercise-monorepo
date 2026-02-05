#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT_DIR/infra/terraform"

if [[ ! -f "$ROOT_DIR/app/image_uri.txt" ]]; then
  echo "ERROR: app/image_uri.txt not found. Run: make app-build-push"
  exit 1
fi

IMAGE_URI="$(cat "$ROOT_DIR/app/image_uri.txt")"
MONGO_URI="$(cd "$TF_DIR" && terraform output -raw mongo_connection_string)"

echo "Deploying namespace + secret..."
kubectl apply -f "$ROOT_DIR/app/k8s/namespace.yaml"
kubectl -n wizapp create secret generic mongo-conn       --from-literal=MONGODB_URI="$MONGO_URI"       --dry-run=client -o yaml | kubectl apply -f -

echo "Deploying RBAC (cluster-admin binding for app SA)..."
kubectl apply -f "$ROOT_DIR/app/k8s/rbac.yaml"

echo "Deploying app (image=$IMAGE_URI)..."
sed "s|__IMAGE_URI__|$IMAGE_URI|g" "$ROOT_DIR/app/k8s/deployment.yaml" | kubectl apply -f -

echo "Deploying service + ingress..."
kubectl apply -f "$ROOT_DIR/app/k8s/service.yaml"
kubectl apply -f "$ROOT_DIR/app/k8s/ingress.yaml"

echo "Waiting for pods..."
kubectl -n wizapp rollout status deploy/wizapp --timeout=180s || true

echo "Ingress:"
kubectl -n wizapp get ingress
