#!/usr/bin/env bash
set -euo pipefail

# Verify at least one recent object exists under prefix
echo "Bucket: $BACKUPS_BUCKET"
echo "Prefix: $BACKUPS_PREFIX"

aws s3api list-objects-v2 \
  --bucket "$BACKUPS_BUCKET" \
  --prefix "$BACKUPS_PREFIX" \
  --max-items 5 \
  --query 'Contents[].Key' --output json

count=$(aws s3api list-objects-v2 --bucket "$BACKUPS_BUCKET" --prefix "$BACKUPS_PREFIX" --query 'length(Contents[])' --output text 2>/dev/null || echo "0")
if [[ "$count" == "0" || "$count" == "None" ]]; then
  echo "No backups found under s3://$BACKUPS_BUCKET/$BACKUPS_PREFIX"
  exit 1
fi

echo "Found $count backup object(s)."
exit 0
