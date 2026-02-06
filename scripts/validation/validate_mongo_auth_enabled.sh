#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

: "${AWS_REGION:?}"
: "${MONGO_TAG_KEY:?}"
: "${MONGO_TAG_VALUE:?}"

iid=$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --filters "Name=tag:${MONGO_TAG_KEY},Values=${MONGO_TAG_VALUE}" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

if [[ -z "${iid:-}" || "$iid" == "None" ]]; then
  log "FAIL: Could not find running Mongo VM by tag ${MONGO_TAG_KEY}=${MONGO_TAG_VALUE}"
  exit 1
fi

log "InstanceId: $iid"

# Use SSM to execute a local command on the VM.
# This requires:
# - SSM agent installed on the AMI (Ubuntu usually has it available or installed by userdata)
# - instance profile permissions for SSM (AmazonSSMManagedInstanceCore)
# - your IAM user/role running this workflow has ssm:SendCommand + ssm:GetCommandInvocation
cmd_id=$(aws ssm send-command \
  --region "$AWS_REGION" \
  --instance-ids "$iid" \
  --document-name "AWS-RunShellScript" \
  --comment "Check MongoDB auth requires credentials" \
  --parameters commands='
set -euo pipefail
if command -v mongosh >/dev/null 2>&1; then
  CLI=mongosh
else
  CLI=mongo
fi

# Attempt unauthenticated admin read; should be rejected when auth enabled.
OUT=$($CLI --quiet --eval "db.getSiblingDB(\"admin\").runCommand({ connectionStatus: 1 })" 2>&1 || true)
echo "$OUT"

# Pass criteria: output indicates not authorized / requires authentication.
echo "$OUT" | grep -Eqi "(not authorized|Unauthorized|requires authentication|Authentication failed)" && exit 0

echo "Did not detect auth rejection; Mongo may be running without authorization enabled."
exit 1
' \
  --query 'Command.CommandId' --output text)

# Wait for command result
for _ in $(seq 1 30); do
  status=$(aws ssm get-command-invocation \
    --region "$AWS_REGION" \
    --command-id "$cmd_id" \
    --instance-id "$iid" \
    --query 'Status' --output text 2>/dev/null || true)

  case "$status" in
    Success|Failed|TimedOut|Cancelled) break ;;
    *) sleep 5 ;;
  esac
done

rc=$(aws ssm get-command-invocation \
  --region "$AWS_REGION" \
  --command-id "$cmd_id" \
  --instance-id "$iid" \
  --query 'ResponseCode' --output text)

if [[ "$rc" == "0" ]]; then
  log "PASS: MongoDB auth enabled (unauthenticated access denied)."
  exit 0
fi

log "FAIL: MongoDB auth check did not detect auth rejection."
aws ssm get-command-invocation --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$iid" \
  --query '{Stdout:StandardOutputContent, Stderr:StandardErrorContent}' --output json || true
exit 1
