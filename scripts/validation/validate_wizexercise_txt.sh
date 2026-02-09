#!/usr/bin/env bash
set -euo pipefail

pod=$(kubectl -n "$K8S_NAMESPACE" get pods -l app="$APP_DEPLOYMENT_NAME" -o jsonpath='{.items[0].metadata.name}')
[[ -n "$pod" ]] || { echo "No pod found for app=$APP_DEPLOYMENT_NAME"; exit 1; }

echo "Pod: $pod"

kubectl -n "$K8S_NAMESPACE" exec "$pod" -c "$APP_CONTAINER_NAME" -- sh -lc "ls -l /app/wizexercise.txt && cat /app/wizexercise.txt"
content=$(kubectl -n "$K8S_NAMESPACE" exec "$pod" -c "$APP_CONTAINER_NAME" -- sh -lc "cat /app/wizexercise.txt" | tr -d '\r')

if [[ "$content" != "$EXPECTED_NAME" ]]; then
  echo "wizexercise.txt content mismatch. Expected '$EXPECTED_NAME' got '$content'"
  exit 1
fi

echo "wizexercise.txt exists and matches expected name."
