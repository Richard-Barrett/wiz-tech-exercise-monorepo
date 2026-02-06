#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

: "${AWS_REGION:?}"
: "${MONGO_TAG_KEY:?}"
: "${MONGO_TAG_VALUE:?}"
: "${BACKUPS_BUCKET:?}"
: "${BACKUPS_PREFIX:?}"

RUN_BACKUP_NOW="${RUN_BACKUP_NOW:-false}"

iid=$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --filters "Name=tag:${MONGO_TAG_KEY},Values=${MONGO_TAG_VALUE}" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

if [[ -z "${iid:-}" || "$iid" == "None" ]]; then
  log "FAIL: Could not find running Mongo VM by tag ${MONGO_TAG_KEY}=${MONGO_TAG_VALUE}"
  exit 1
fi
log "Mongo InstanceId: $iid"

ping=$(aws ssm describe-instance-information \
  --region "$AWS_REGION" \
  --filters "Key=InstanceIds,Values=$iid" \
  --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)

if [[ -z "${ping:-}" || "$ping" == "None" ]]; then
  log "FAIL: Instance not registered in SSM (cannot inspect cron or run backup)."
  exit 1
fi
if [[ "$ping" != "Online" ]]; then
  log "FAIL: SSM PingStatus=$ping (expected Online)"
  exit 1
fi
log "SSM PingStatus: $ping"

cmds='
set -euo pipefail
set -x

echo "=== cron + script ==="
ls -l /usr/local/bin/mongo_backup_to_s3.sh || true
ls -l /etc/cron.d/mongo_backup || true

if [[ ! -x /usr/local/bin/mongo_backup_to_s3.sh ]]; then
  echo "Backup script missing or not executable"
  exit 1
fi

if [[ ! -f /etc/cron.d/mongo_backup ]]; then
  echo "Cron file missing"
  exit 1
fi

echo "=== cron contents ==="
cat /etc/cron.d/mongo_backup
'

if [[ "$RUN_BACKUP_NOW" == "true" ]]; then
  cmds+=$'\n'"echo '=== RUN_BACKUP_NOW=true: running backup once ==='"
  cmds+=$'\n'"/usr/local/bin/mongo_backup_to_s3.sh"
fi

cmd_id=$(aws ssm send-command \
  --region "$AWS_REGION" \
  --instance-ids "$iid" \
  --document-name "AWS-RunShellScript" \
  --comment "Validate backup config and optionally run backup now" \
  --parameters commands="$cmds" \
  --query 'Command.CommandId' --output text)

for _ in $(seq 1 30); do
  st=$(aws ssm get-command-invocation --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$iid" --query 'Status' --output text 2>/dev/null || true)
  case "$st" in Success|Failed|TimedOut|Cancelled) break ;; *) sleep 3 ;; esac
done

inv=$(aws ssm get-command-invocation --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$iid" --output json)
rc=$(jq -r '.ResponseCode' <<<"$inv")
st=$(jq -r '.Status' <<<"$inv")

if [[ "$rc" != "0" ]]; then
  log "FAIL: Backup config/run failed (SSM Status=$st, RC=$rc)"
  log "STDOUT:"
  jq -r '.StandardOutputContent' <<<"$inv" || true
  log "STDERR:"
  jq -r '.StandardErrorContent' <<<"$inv" || true
  exit 1
fi

log "Backup cron/script verified on VM."

log "Checking for objects in s3://$BACKUPS_BUCKET/$BACKUPS_PREFIX"
count=$(aws s3api list-objects-v2 \
  --region "$AWS_REGION" \
  --bucket "$BACKUPS_BUCKET" \
  --prefix "$BACKUPS_PREFIX" \
  --query 'length(Contents)' --output text 2>/dev/null || echo "0")

[[ "$count" == "None" ]] && count="0"

if (( count < 1 )); then
  log "FAIL: No backup objects found under s3://$BACKUPS_BUCKET/$BACKUPS_PREFIX"
  log "If cron hasn't run yet, set RUN_BACKUP_NOW=true in workflow env."
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
