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

ping=$(aws ssm describe-instance-information \
  --region "$AWS_REGION" \
  --filters "Key=InstanceIds,Values=$iid" \
  --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)

if [[ -z "${ping:-}" || "$ping" == "None" ]]; then
  log "FAIL: Instance not registered in SSM (cannot run remote validation)."
  exit 1
fi
if [[ "$ping" != "Online" ]]; then
  log "FAIL: SSM PingStatus=$ping (expected Online)"
  exit 1
fi
log "SSM PingStatus: $ping"

cmd_id=$(aws ssm send-command \
  --region "$AWS_REGION" \
  --instance-ids "$iid" \
  --document-name "AWS-RunShellScript" \
  --comment "Validate MongoDB authorization enabled + unauth access denied" \
  --parameters commands='
set -euo pipefail

echo "=== mongod status ==="
systemctl is-active mongod || (systemctl status mongod --no-pager || true; exit 1)

echo "=== listening ports ==="
(ss -lntp || netstat -lntp) 2>/dev/null | grep -E ":(27017)\b" || true

echo "=== /etc/mongod.conf security section ==="
awk "BEGIN{p=0} /^security:/{p=1} p==1{print} /^$/{if(p==1) exit}" /etc/mongod.conf || true

if ! grep -Eq "^[[:space:]]*authorization:[[:space:]]*enabled" /etc/mongod.conf; then
  echo "authorization: enabled NOT found in /etc/mongod.conf"
  exit 1
fi

CLI=""
if command -v mongosh >/dev/null 2>&1; then
  CLI="mongosh"
elif command -v mongo >/dev/null 2>&1; then
  CLI="mongo"
else
  echo "Neither mongosh nor mongo is installed/available in PATH"
  exit 1
fi

echo "=== trying unauth commands (should be denied) using $CLI ==="

try_cmd () {
  local js="$1"
  echo "--- JS: $js"
  OUT=$($CLI --quiet --eval "$js" 2>&1 || true)
  echo "$OUT"
  echo "$OUT" | grep -Eqi "(not authorized|Unauthorized|requires authentication|Authentication failed|auth.*failed)" && return 0
  return 1
}

# Try a few commands that should require auth when authorization is enabled
try_cmd "db.getSiblingDB(\"admin\").runCommand({ usersInfo: 1 })" && exit 0
try_cmd "db.getSiblingDB(\"admin\").getUsers()" && exit 0
try_cmd "db.getSiblingDB(\"admin\").runCommand({ getLog: \"global\" })" && exit 0

echo "No auth-denial detected. This usually means authorization is NOT enforced at runtime."
exit 1
' \
  --query 'Command.CommandId' --output text)

# wait
for _ in $(seq 1 30); do
  st=$(aws ssm get-command-invocation --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$iid" --query 'Status' --output text 2>/dev/null || true)
  case "$st" in Success|Failed|TimedOut|Cancelled) break ;; *) sleep 3 ;; esac
done

inv=$(aws ssm get-command-invocation --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$iid" --output json)
rc=$(jq -r '.ResponseCode' <<<"$inv")
st=$(jq -r '.Status' <<<"$inv")

if [[ "$rc" == "0" ]]; then
  log "PASS: MongoDB auth enabled (unauthenticated access denied)."
  exit 0
fi

log "FAIL: Mongo auth check failed (SSM Status=$st, RC=$rc)"
log "STDOUT:"
jq -r '.StandardOutputContent' <<<"$inv" || true
log "STDERR:"
jq -r '.StandardErrorContent' <<<"$inv" || true
exit 1
