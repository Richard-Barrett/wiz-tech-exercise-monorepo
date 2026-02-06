#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

: "${AWS_REGION:?}"
: "${MONGO_TAG_KEY:?}"
: "${MONGO_TAG_VALUE:?}"
: "${BACKUPS_BUCKET:?}"
: "${BACKUPS_PREFIX:?}"

iid=$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --filters "Name=tag:${MONGO_TAG_KEY},Values=${MONGO_TAG_VALUE}" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

if [[ -z "${iid:-}" || "$iid" == "None" ]]; then
  log "FAIL: Could not find running Mongo VM by tag ${MONGO_TAG_KEY}=${MONGO_TAG_VALUE}"
  exit 1
fi

log "InstanceId: $iid"

cmd_id=$(aws ssm send-command \
  --region "$AWS_REGION" \
  --instance-ids "$iid" \
  --document-name "AWS-RunShellScript" \
  --comment "Check backup script + cron are configured" \
  --parameters commands='
set -euo pipefail

# Expected from your userdata:
# - /usr/local/bin/mongo_backup_to_s3.sh
# - /etc/cron.d/mongo_backup (or similar)
script_ok=0
cron_ok=0

[[ -x /usr/local/bin/mongo_backup_to_s3.sh ]] && script_ok=1
[[ -f /etc/cron.d/mongo_backup ]] && cron_ok=1

echo "script_ok=$script_ok"
echo "cron_ok=$cron_ok"

# Basic content check: cron references the script
if [[ "$cron_ok" -eq 1 ]]; then
  grep -q "/usr/local/bin/mongo_backup_to_s3.sh" /etc/cron.d/mongo_backup && echo "cron_references_script=1" || echo "cron_references_script=0"
else
  echo "cron_references_script=0"
fi

if [[ "$script_ok" -eq 1 && "$cron_ok" -eq 1 ]] && grep -q "/usr/local/bin/mongo_backup_to_s3.sh" /etc/cron.d/mongo_backup; then
  exit 0
fi

echo "Backup cron/script not configured as expected."
exit 1
' \
  --query 'Command.CommandId' --output text)

# Wait
for _ in $(seq 1 30); do
  status=$(aws ssm get-command-invocation \
    --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$iid" \
    --query 'Status' --output text 2>/dev/null || true)
  case "$status" in
    Success|Failed|TimedOut|Cancelled) break ;;
    *) sleep 5 ;;
  esac
done

rc=$(aws ssm get-command-invocation \
  --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$iid" \
  --query 'ResponseCode' --output text)

if [[ "$rc" != "0" ]]; then
  log "FAIL: Backup scheduling not configured on VM."
  aws ssm get-command-invocation --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$iid" \
    --query '{Stdout:StandardOutputContent, Stderr:StandardErrorContent}' --output json || true
  exit 1
fi

log "Backup schedule looks configured. Now checking for a recent object in S3..."

# Check S3 for last 36 hours (daily + buffer)
cutoff_epoch=$(date -u -d "36 hours ago" +%s)

# List latest object under prefix (may be empty if backups haven't run yet)
latest=$(aws s3api list-objects-v2 \
  --region "$AWS_REGION" \
  --bucket "$BACKUPS_BUCKET" \
  --prefix "$BACKUPS_PREFIX" \
  --query 'sort_by(Contents,&LastModified)[-1].{Key:Key,LastModified:LastModified}' \
  --output json 2>/dev/null || true)

if [[ -z "${latest:-}" || "$latest" == "null" ]]; then
  log "FAIL: No backup objects found in s3://$BACKUPS_BUCKET/$BACKUPS_PREFIX"
  exit 1
fi

key=$(jq -r '.Key // empty' <<<"$latest")
lm=$(jq -r '.LastModified // empty' <<<"$latest")

if [[ -z "$key" || -z "$lm" ]]; then
  log "FAIL: Could not parse latest backup object."
  echo "$latest"
  exit 1
fi

lm_epoch=$(date -u -d "$lm" +%s)

log "Latest backup object: s3://$BACKUPS_BUCKET/$key (LastModified=$lm)"

if (( lm_epoch >= cutoff_epoch )); then
  log "PASS: Daily backups configured and recent backup object exists."
  exit 0
fi

log "FAIL: Found backups, but latest is older than ~36 hours."
exit 1
