#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

: "${AWS_REGION:?}"
: "${MONGO_TAG_KEY:?}"
: "${MONGO_TAG_VALUE:?}"
: "${BACKUPS_BUCKET:?}"
: "${BACKUPS_PREFIX:?}"

echo "=== Backup Validation Check ==="

# 1. Check if backup cron/schedule exists on VM
iid=$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --filters "Name=tag:${MONGO_TAG_KEY},Values=${MONGO_TAG_VALUE}" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

if [[ -z "${iid:-}" || "$iid" == "None" ]]; then
  log "FAIL: Could not find Mongo VM"
  exit 1
fi

log "Checking backup configuration on instance: $iid"

# Check for backup configuration on VM
cmd_id=$(aws ssm send-command \
  --region "$AWS_REGION" \
  --instance-ids "$iid" \
  --document-name "AWS-RunShellScript" \
  --comment "Check backup configuration" \
  --parameters commands='
set -euo pipefail

echo "1. Checking for backup cron jobs..."
crontab -l 2>/dev/null | grep -i "mongodb\|backup" || true
ls -la /etc/cron.d/ 2>/dev/null | grep -i "mongodb\|backup" || true
grep -r "mongodb\|backup" /etc/cron.d/ /etc/cron.*/ 2>/dev/null | head -5 || true

echo ""
echo "2. Checking for backup scripts..."
find /usr/local/bin /opt /home -name "*backup*" -type f 2>/dev/null | head -10

echo ""
echo "3. Checking for recent local backups..."
find /var/lib/mongodb /opt /tmp -name "*mongodump*" -o -name "*backup*" -type f -mtime -7 2>/dev/null | head -5

echo ""
echo "4. Checking MongoDB backup tools..."
which mongodump 2>/dev/null || echo "mongodump not found"
' \
  --query 'Command.CommandId' --output text)

# Wait briefly for command
sleep 10

# 2. Check S3 for recent backups
log "Checking S3 bucket for recent backups..."
BACKUP_COUNT=$(aws s3api list-objects-v2 \
  --bucket "${BACKUPS_BUCKET}" \
  --prefix "${BACKUPS_PREFIX}" \
  --query "length(Contents[?LastModified >=\`$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)\`])" \
  --output text 2>/dev/null || echo "0")

# Also check for any backups at all
ANY_BACKUPS=$(aws s3api list-objects-v2 \
  --bucket "${BACKUPS_BUCKET}" \
  --prefix "${BACKUPS_PREFIX}" \
  --query "length(Contents[])" \
  --output text 2>/dev/null || echo "0")

log "Found $BACKUP_COUNT backup(s) from last 7 days"
log "Found $ANY_BACKUPS total backup(s) in bucket"

# Get VM check results
inv=$(aws ssm get-command-invocation \
  --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$iid" \
  --output json 2>/dev/null || echo '{"StandardOutputContent": "Could not retrieve SSM output"}')

stdout=$(jq -r '.StandardOutputContent' <<<"$inv")
echo "=== Backup configuration on VM ==="
echo "$stdout"

# Determine pass/fail
if [[ "$BACKUP_COUNT" -gt 0 ]]; then
  echo "✅ PASS: Found recent backups in S3 (last 7 days)"
  exit 0
elif [[ "$ANY_BACKUPS" -gt 0 ]]; then
  echo "⚠️  WARNING: Found backups in S3, but none in last 7 days"
  echo "❌ FAIL: No recent backups found"
  exit 1
else
  echo "❌ FAIL: No backups found in S3 bucket"
  exit 1
fi