#!/usr/bin/env bash
set -euo pipefail

bucket="$BACKUPS_BUCKET"

echo "Checking bucket policy for public read AND list permissions..."
policy=$(aws s3api get-bucket-policy --bucket "$bucket" --query Policy --output text 2>/dev/null || true)
if [[ -z "$policy" || "$policy" == "None" ]]; then
  echo "No bucket policy found. Public listing/read unlikely."
  exit 1
fi

echo "$policy" | jq .

# Best-effort: look for Principal:"*" and Action including s3:GetObject and s3:ListBucket
has_get=$(echo "$policy" | jq -e '
  .Statement[] | select(.Principal=="*" or .Principal.AWS=="*")
  | select((.Action|type=="string" and .Action=="s3:GetObject") or (.Action|type=="array" and (index("s3:GetObject")!=null)))
' >/dev/null && echo "yes" || echo "no")

has_list=$(echo "$policy" | jq -e '
  .Statement[] | select(.Principal=="*" or .Principal.AWS=="*")
  | select((.Action|type=="string" and .Action=="s3:ListBucket") or (.Action|type=="array" and (index("s3:ListBucket")!=null)))
' >/dev/null && echo "yes" || echo "no")

echo "Public GetObject: $has_get"
echo "Public ListBucket: $has_list"

if [[ "$has_get" == "yes" && "$has_list" == "yes" ]]; then
  echo "Bucket policy appears to allow public read + listing."
  exit 0
fi

echo "Bucket policy does not clearly allow both public read and listing."
exit 1
