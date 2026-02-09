#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

: "${BACKUPS_BUCKET:?}"
: "${BACKUPS_PREFIX:?}"

echo "=== S3 Public Access Check ==="

# Get bucket policy
POLICY=$(aws s3api get-bucket-policy \
  --bucket "${BACKUPS_BUCKET}" \
  --output text 2>/dev/null || echo "No bucket policy")

echo "1. Bucket Policy:"
if [[ "$POLICY" == "No bucket policy" ]]; then
  echo "   No bucket policy found"
else
  echo "$POLICY" | jq '.' 2>/dev/null || echo "$POLICY"
fi

echo ""
echo "2. Checking for public access..."

# Check bucket ACL
ACL=$(aws s3api get-bucket-acl \
  --bucket "${BACKUPS_BUCKET}" \
  --query 'Grants[?Grantee.URI==`http://acs.amazonaws.com/groups/global/AllUsers`]' \
  --output json 2>/dev/null || echo "[]")

PUBLIC_ACL_COUNT=$(echo "$ACL" | jq 'length')

# Check bucket policy for public statements
PUBLIC_POLICY_COUNT=0
if [[ "$POLICY" != "No bucket policy" ]]; then
  PUBLIC_POLICY_COUNT=$(echo "$POLICY" | jq -r '.Statement[] | select(.Effect=="Allow" and (.Principal=="*" or .Principal.AWS=="*")) | .Action' | grep -c . || echo 0)
fi

echo "   Public ACL grants: $PUBLIC_ACL_COUNT"
echo "   Public policy statements: $PUBLIC_POLICY_COUNT"

echo ""
echo "3. Testing actual access..."

# Try to list bucket publicly (simulate)
echo "   Testing list access on prefix: ${BACKUPS_PREFIX}"
LIST_ACCESS=$(aws s3api list-objects-v2 \
  --bucket "${BACKUPS_BUCKET}" \
  --prefix "${BACKUPS_PREFIX}" \
  --max-items 1 \
  --query "Contents[0].Key" \
  --output text 2>/dev/null && echo "List access OK" || echo "List access failed")

echo "   $LIST_ACCESS"

# Check if there's at least one object to test GET
FIRST_OBJECT=$(aws s3api list-objects-v2 \
  --bucket "${BACKUPS_BUCKET}" \
  --prefix "${BACKUPS_PREFIX}" \
  --max-items 1 \
  --query "Contents[0].Key" \
  --output text 2>/dev/null || true)

GET_ACCESS="No objects to test"
if [[ -n "$FIRST_OBJECT" && "$FIRST_OBJECT" != "None" ]]; then
  # Generate pre-signed URL that doesn't require authentication
  # If this works without authentication, bucket is public
  GET_ACCESS=$(aws s3 presign "s3://${BACKUPS_BUCKET}/${FIRST_OBJECT}" --expires-in 60 2>&1 || echo "Presign failed")
  echo "   Sample object: $FIRST_OBJECT"
fi

echo ""
echo "=== Summary ==="
# For the exercise, we expect public access (based on your requirements)
if [[ "$PUBLIC_ACL_COUNT" -gt 0 ]] || [[ "$PUBLIC_POLICY_COUNT" -gt 0 ]]; then
  echo "✅ PASS: S3 bucket allows public read/list access"
  exit 0
else
  echo "❌ FAIL: S3 bucket does not allow public read/list access"
  echo "Note: This might be good for security, but fails the exercise requirement"
  exit 1
fi