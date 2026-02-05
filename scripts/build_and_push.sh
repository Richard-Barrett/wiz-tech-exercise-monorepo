#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT_DIR/infra/terraform"

REGION="$(cd "$TF_DIR" && terraform output -raw aws_region)"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REPO_URL="$(cd "$TF_DIR" && terraform output -raw ecr_repo_url)"
YOUR_NAME="$(cd "$TF_DIR" && terraform output -raw your_name)"

IMAGE_TAG="$(date +%Y%m%d%H%M%S)"
IMAGE_URI="${REPO_URL}:${IMAGE_TAG}"

echo "Logging into ECR..."
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

echo "Building image: $IMAGE_URI"
docker build -t "$IMAGE_URI" --build-arg YOUR_NAME="$YOUR_NAME" "$ROOT_DIR/app"

echo "Pushing image..."
docker push "$IMAGE_URI"

echo "Writing image uri to: $ROOT_DIR/app/image_uri.txt"
echo "$IMAGE_URI" > "$ROOT_DIR/app/image_uri.txt"

echo "Done."
