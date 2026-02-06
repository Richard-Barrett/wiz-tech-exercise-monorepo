#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

: "${AWS_REGION:?}"
: "${MONGO_TAG_KEY:?}"
: "${MONGO_TAG_VALUE:?}"
: "${BACKUPS_BUCKET:?}"
: "${BACKUPS_PREFIX:?}"

echo "=== Backup Validation Check ==="

# 1. First, get VM creation time to check age
iid=$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --filters "Name=tag:${MONGO_TAG_KEY},Values=${MONGO_TAG_VALUE}" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

if [[ -z "${iid:-}" || "$iid" == "None" ]]; then
  log "FAIL: Could not find Mongo VM"
  exit 1
fi

# Get VM launch time
LAUNCH_TIME=$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --instance-ids "$iid" \
  --query 'Reservations[0].Instances[0].LaunchTime' \
  --output text)

if [[ -z "$LAUNCH_TIME" || "$LAUNCH_TIME" == "None" ]]; then
  log "WARNING: Could not get VM launch time"
  LAUNCH_TIME_EPOCH=$(date -u +%s)
else
  LAUNCH_TIME_EPOCH=$(date -u -d "$LAUNCH_TIME" +%s)
fi

NOW_EPOCH=$(date -u +%s)
VM_AGE_DAYS=$(( (NOW_EPOCH - LAUNCH_TIME_EPOCH) / 86400 ))

log "VM InstanceId: $iid"
log "VM Launch Time: $LAUNCH_TIME"
log "VM Age: $VM_AGE_DAYS days"

# 2. Check if backup configuration exists on VM
log "Checking backup configuration on instance..."

cmd_id=$(aws ssm send-command \
  --region "$AWS_REGION" \
  --instance-ids "$iid" \
  --document-name "AWS-RunShellScript" \
  --comment "Check backup configuration" \
  --parameters commands='
set -euo pipefail

echo "1. Checking for backup cron jobs/schedules..."
echo "--- Crontab entries ---"
crontab -l 2>/dev/null | grep -i "mongodb\|backup\|dump" || echo "No backup entries in user crontab"

echo ""
echo "--- System cron jobs ---"
ls -la /etc/cron.d/ 2>/dev/null | grep -i "mongodb\|backup\|dump" || echo "No backup files in /etc/cron.d/"
grep -r "mongodb\|backup\|dump\|mongodump" /etc/cron.d/ /etc/cron.*/ 2>/dev/null | head -10 || echo "No backup references in system cron"

echo ""
echo "2. Checking for backup scripts..."
find /usr/local/bin /opt /home -name "*backup*" -o -name "*dump*" -type f 2>/dev/null | head -10 || echo "No backup scripts found"

echo ""
echo "3. Checking MongoDB backup tool..."
which mongodump 2>/dev/null && echo "✓ mongodump found: $(which mongodump)" || echo "✗ mongodump not found"

echo ""
echo "4. Checking for any local backup files..."
find /var/lib /opt /tmp /home -name "*mongo*" -o -name "*backup*" -o -name "*dump*" -type f -mtime -30 2>/dev/null | head -5 || echo "No recent local backup files found"

echo ""
echo "5. Checking AWS CLI availability..."
which aws 2>/dev/null && echo "✓ AWS CLI found: $(aws --version 2>/dev/null | head -1)" || echo "✗ AWS CLI not found"
' \
  --query 'Command.CommandId' --output text)

# Wait for SSM command
sleep 15

# 3. Check S3 for backups
log "Checking S3 bucket for backups..."
BACKUP_COUNT=$(aws s3api list-objects-v2 \
  --bucket "${BACKUPS_BUCKET}" \
  --prefix "${BACKUPS_PREFIX}" \
  --query "length(Contents[?LastModified >=\`$(date -u -d '1 day ago' +%Y-%m-%dT%H:%M:%SZ)\`])" \
  --output text 2>/dev/null || echo "0")

# Check for any backups at all
ANY_BACKUPS=$(aws s3api list-objects-v2 \
  --bucket "${BACKUPS_BUCKET}" \
  --prefix "${BACKUPS_PREFIX}" \
  --query "length(Contents[])" \
  --output text 2>/dev/null || echo "0")

# Get list of recent backups for logging
RECENT_BACKUPS=$(aws s3api list-objects-v2 \
  --bucket "${BACKUPS_BUCKET}" \
  --prefix "${BACKUPS_PREFIX}" \
  --query "Contents[].{Key: Key, LastModified: LastModified}" \
  --output json 2>/dev/null || echo "[]")

log "Found $BACKUP_COUNT backup(s) from last 24 hours"
log "Found $ANY_BACKUPS total backup(s) in bucket"

# Get VM check results
inv=$(aws ssm get-command-invocation \
  --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$iid" \
  --output json 2>/dev/null || echo '{"StandardOutputContent": "Could not retrieve SSM output"}')

stdout=$(jq -r '.StandardOutputContent' <<<"$inv")
echo "=== Backup configuration on VM ==="
echo "$stdout"

echo ""
echo "=== Backup Files in S3 ==="
if [[ "$ANY_BACKUPS" -gt 0 ]]; then
  echo "Recent backups found:"
  echo "$RECENT_BACKUPS" | jq -r '.[] | "  - \(.Key) (\(.LastModified))"' 2>/dev/null || echo "$RECENT_BACKUPS"
else
  echo "No backup files found in S3"
fi

echo ""
echo "=== Validation Decision ==="

# Decision logic based on VM age
if [[ "$VM_AGE_DAYS" -lt 2 ]]; then
  # VM is very new (less than 2 days old)
  echo "✅ VM is only $VM_AGE_DAYS day(s) old"
  echo "✅ PASS: VM is too new to require daily backups yet"
  echo "   Note: Backup configuration should still be set up for future backups"
  exit 0
  
elif [[ "$VM_AGE_DAYS" -lt 7 ]]; then
  # VM is less than 7 days old
  if [[ "$ANY_BACKUPS" -gt 0 ]]; then
    echo "✅ VM is $VM_AGE_DAYS days old and has $ANY_BACKUPS backup(s)"
    echo "✅ PASS: Backups exist for this young VM"
    exit 0
  else
    echo "⚠️  VM is $VM_AGE_DAYS days old but no backups found"
    echo "❌ FAIL: Should have at least one backup by now"
    exit 1
  fi
  
else
  # VM is 7+ days old - should have regular backups
  if [[ "$BACKUP_COUNT" -gt 0 ]]; then
    echo "✅ VM is $VM_AGE_DAYS days old and has recent backup(s)"
    echo "✅ PASS: Daily backup requirement satisfied"
    exit 0
  elif [[ "$ANY_BACKUPS" -gt 0 ]]; then
    echo "⚠️  VM is $VM_AGE_DAYS days old, has $ANY_BACKUPS backup(s) but none in last 24h"
    echo "❌ FAIL: No recent daily backup found"
    exit 1
  else
    echo "❌ VM is $VM_AGE_DAYS days old but no backups found at all"
    echo "❌ FAIL: No backups configured or working"
    exit 1
  fi
fi