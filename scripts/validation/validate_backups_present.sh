#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

: "${AWS_REGION:?}"
: "${MONGO_TAG_KEY:?}"
: "${MONGO_TAG_VALUE:?}"
: "${BACKUPS_BUCKET:?}"
: "${BACKUPS_PREFIX:?}"

RUN_BACKUP_NOW="${RUN_BACKUP_NOW:-false}"   # set true in workflow env if you want

iid=$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --filters "Name=tag:${MONGO_TAG_KEY},Values=${MONGO_TAG_VALUE}" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

if [[ -z "${iid:-}" || "$iid" == "None" ]]; then
  log "FAIL: Could not find running Mongo VM by tag ${MONGO_TAG_KEY}=${MONGO_TAG_VALUE}"
  exit 1
fi
log "Mongo InstanceId: $iid"

ssm_online=$(aws ssm describe-instance-information \
  --region "$AWS_REGION" \
  --filters "Key=InstanceIds,Values=$iid" \
  --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)

if [[ -z "${ssm_online:-}" || "$ssm_online" == "None" ]]; then
  log "FAIL: Instance is not registered in SSM."
  log "Fix: install/enable SSM agent + attach instance profile with AmazonSSMManagedInstanceCore."
  exit 1
fi
if [[ "$ssm_online" != "Online" ]]; then
  log "FAIL: SSM PingStatus is '$ssm_online' (expected Online)."
  exit 1
fi
log "SSM PingStatus: $ssm_online"

cmds='
set -euo pipefail

echo "--- checking backup script + cron ---"
ls -l /usr/local/bin/mongo_backup_to_s3.sh || true
ls -l /etc/cron.d/mongo_backup || true

if [[ ! -x /usr/local/bin/mongo_backup_to_s3.sh ]]; then
  echo "Backup script missing or not executable: /usr/local/bin/mongo_backup_to_s3.sh"
  exit 1
fi

if [[ ! -f /etc/cron.d/mongo_backup ]]; then
  echo "Cron file missing: /etc/cron.d/mongo_backup"
  exit 1
fi

grep -n "mongo_backup_to_s3.sh" /etc/cron.d/mongo_backup || true
'

if [[ "$RUN_BACKUP_NOW" == "true" ]]; then
  cmds+=$'\n'"echo \"--- RUN_BACKUP_NOW=true: executing backup once ---\""
  cmds+=$'\n'"sudo /usr/local/bin/mongo_backup_to_s3.sh || (echo \"Backup script failed\"; exit 1)"
fi

cmd_id=$(aws ssm send-command \
  --region "$AWS_REGION" \
  --instance-ids "$iid" \
  --document-name "AWS-RunShellScript" \
  --comment "Check backup cron/script and optionally execute backup" \
  --parameters commands="$cmds" \
  --query 'Command.CommandId' --output text)

for _ in $(seq 1 30); do
  status=$(aws ssm get-command-invocation \
    --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$iid" \
    --query 'Status' --output text 2>/dev/null || true)
  case "$status" in
    Success|Failed|TimedOut|Cancelled) break ;;
    *) sleep 5 ;;
  esac
done

inv=$(aws ssm get-command-invocation \
  --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$iid" \
  --output json)

rc=$(jq -r '.ResponseCode' <<<"$inv")
status=$(jq -r '.Status' <<<"$inv")

if [[ "$rc" != "0" ]]; then
  log "FAIL: Backup scheduling/config check failed. SSM Status=$status ResponseCode=$rc"
  log "STDOUT:"
  jq -r '.StandardOutputContent' <<<"$inv" || true
  log "STDERR:"
  jq -r '.StandardErrorContent' <<<"$inv" || true
  exit 1
fi

log "Backup script + cron look configured."

log "Checking S3 for backup objects: s3://$BACKUPS_BUCKET/$BACKUPS_PREFIX"
count=$(aws s3api list-objects-v2 \
  --region "$AWS_REGION" \
  --bucket "$BACKUPS_BUCKET" \
  --prefix "$BACKUPS_PREFIX" \
  --query 'length(Contents)' --output text 2>/dev/null || echo "0")

if [[ "$count" == "None" ]]; then
  count="0"
fi

if (( count < 1 )); then
  log "FAIL: No objects found under s3://$BACKUPS_BUCKET/$BACKUPS_PREFIX"
  log "Most common causes:"
  log " - Backup cron hasn't run yet (set RUN_BACKUP_NOW=true to force one)."
  log " - VM role lacks s3:PutObject to this bucket/prefix."
  log " - BACKUPS_BUCKET/BACKUPS_PREFIX are not the backup destination."
  exit 1
fi

latest=$(aws s3api list-objects-v2 \
  --region "$AWS_REGION" \
  --bucket "$BACKUPS_BUCKET" \
  --prefix "$BACKUPS_PREFIX" \
  --query 'sort_by(Contents,&LastModified)[-1].{Key:Key,LastModified:LastModified,Size:Size}' \
  --output json)

log "PASS: Found $count object(s). Latest:"
echo "$latest" | jq .
exit 0
