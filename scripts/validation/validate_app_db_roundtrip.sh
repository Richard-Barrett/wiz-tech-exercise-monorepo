#!/usr/bin/env bash
set -euo pipefail

pod=$(kubectl -n "$K8S_NAMESPACE" get pods -l app="$APP_DEPLOYMENT_NAME" -o jsonpath='{.items[0].metadata.name}')
[[ -n "$pod" ]] || { echo "No pod found for app=$APP_DEPLOYMENT_NAME"; exit 1; }

# Validate health
kubectl -n "$K8S_NAMESPACE" exec "$pod" -c "$APP_CONTAINER_NAME" -- sh -lc "wget -qO- http://localhost:3000/api/health || curl -fsS http://localhost:3000/api/health"

echo
echo "Health endpoint OK."

# OPTIONAL: If your app has an endpoint that writes+reads (ex: /api/todos), call it here.
# If not, we at least prove env var exists and app is running.
echo "NOTE: Update this script to hit your real CRUD endpoint (e.g., POST/GET /api/todos) to *prove* DB roundtrip."
