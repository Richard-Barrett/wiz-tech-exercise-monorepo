#!/usr/bin/env bash
set -euo pipefail

kubectl -n "$K8S_NAMESPACE" get deploy "$APP_DEPLOYMENT_NAME" -o json \
  | jq -e '
    .spec.template.spec.containers[]
    | select(.name=="'"$APP_CONTAINER_NAME"'")
    | .env[]?
    | select(.name=="MONGODB_URI")
  ' >/dev/null

echo "MONGODB_URI env var exists on container $APP_CONTAINER_NAME."
