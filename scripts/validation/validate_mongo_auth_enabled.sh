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
log "Mongo InstanceId: $iid"

# --- SSM sanity check (super common reason for “instant failures”) ---
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

# Run local unauth probe on the VM:
# 1) confirm mongod.conf has authorization enabled
# 2) attempt admin command that should require auth (usersInfo)
cmd_id=$(aws ssm send-command \
  --region "$AWS_REGION" \
  --instance-ids "$iid" \
  --document-name "AWS-RunShellScript" \
  --comment "Check MongoDB authorization is enabled and unauth access is denied" \
  --parameters commands='
set -euo pipefail

echo "--- mongod.conf security section ---"
awk "BEGIN{p=0} /^security:/{p=1} p==1{print} /^$/{if(p==1) exit}" /etc/mongod.conf || true

if ! grep -Eq "^[[:space:]]*authorization:[[:space:]]*enabled" /etc/mongod.conf; then
  echo "authorization: enabled not found in /etc/mongod.conf"
  exit 1
fi

if command -v mongosh >/dev/null 2>&1; then
  CLI=mongosh
else
  CLI=mongo
fi

echo "--- attempting unauth admin command (usersInfo) ---"
OUT=$($CLI --quiet --eval "db.getSiblingDB(\"admin\").runCommand({ usersInfo: 1 })" 2>&1 || true)
echo "$OUT"

# Pass if we see an auth-related failure
echo "$OUT" | grep -Eqi "(not authorized|Unauthorized|requires authentication|Authentication failed)" && exit 0

echo "Did not detect auth rejection. Mongo may allow unauth admin commands (auth disabled or misconfigured)."
exit 1
' \
  --query 'Command.CommandId' --output text)

# Wait + print details on failure
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

inv=$(aws ssm get-command-invocation \
  --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$iid" \
  --output json)

rc=$(jq -r '.ResponseCode' <<<"$inv")
status=$(jq -r '.Status' <<<"$inv")

if [[ "$rc" == "0" ]]; then
  log "PASS: MongoDB auth enabled (unauthenticated access denied)."
  exit 0
fi

log "FAIL: MongoDB auth check failed. SSM Status=$status ResponseCode=$rc"
log "STDOUT:"
jq -r '.StandardOutputContent' <<<"$inv" || true
log "STDERR:"
jq -r '.StandardErrorContent' <<<"$inv" || true
exit 1
