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

# Check SSM status
ssm_online=$(aws ssm describe-instance-information \
  --region "$AWS_REGION" \
  --filters "Key=InstanceIds,Values=$iid" \
  --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)

if [[ -z "${ssm_online:-}" || "$ssm_online" == "None" ]]; then
  log "FAIL: Instance is not registered in SSM."
  exit 1
fi

if [[ "$ssm_online" != "Online" ]]; then
  log "FAIL: SSM PingStatus is '$ssm_online' (expected Online)."
  exit 1
fi
log "SSM PingStatus: $ssm_online"

# Run check on VM
cmd_id=$(aws ssm send-command \
  --region "$AWS_REGION" \
  --instance-ids "$iid" \
  --document-name "AWS-RunShellScript" \
  --comment "Check MongoDB authorization" \
  --parameters commands='
set -euo pipefail

echo "=== MongoDB Authentication Check ==="

# Check if MongoDB is running
if ! systemctl is-active --quiet mongod 2>/dev/null; then
  echo "ERROR: MongoDB service is not running"
  exit 1
fi

echo "1. Checking /etc/mongod.conf for authentication settings..."
if [[ ! -f /etc/mongod.conf ]]; then
  echo "ERROR: /etc/mongod.conf not found"
  exit 1
fi

# Extract security section
echo "--- Security section from mongod.conf ---"
grep -A5 "^security:" /etc/mongod.conf || echo "No security section found"

# Check for authorization: enabled
AUTH_ENABLED=false
if grep -q "^[[:space:]]*authorization:[[:space:]]*enabled" /etc/mongod.conf; then
  echo "✓ Found 'authorization: enabled' in config"
  AUTH_ENABLED=true
else
  echo "✗ 'authorization: enabled' NOT found in config"
fi

echo ""
echo "2. Testing unauthenticated access..."

# Try to run a command without authentication
TIMEOUT=10
UNAUTH_OUTPUT=""
UNAUTH_SUCCESS=false

# Use mongosh if available, otherwise mongo
if command -v mongosh >/dev/null 2>&1; then
  CLI="mongosh --quiet --eval"
else
  CLI="mongo --quiet --eval"
fi

# Try unauthenticated command with timeout
if timeout $TIMEOUT bash -c "$CLI \"db.adminCommand({ping: 1})\" 2>&1" > /tmp/unauth_test.txt; then
  UNAUTH_OUTPUT=$(cat /tmp/unauth_test.txt)
  if echo "$UNAUTH_OUTPUT" | grep -qi "ok.*1"; then
    UNAUTH_SUCCESS=true
    echo "✗ Unauthenticated command SUCCEEDED (security issue!)"
    echo "Output: $UNAUTH_OUTPUT"
  fi
else
  UNAUTH_OUTPUT=$(cat /tmp/unauth_test.txt)
  echo "✓ Unauthenticated command failed (as expected)"
  echo "Error: $UNAUTH_OUTPUT"
fi

echo ""
echo "=== Summary ==="
if [[ "$AUTH_ENABLED" == "true" ]] && [[ "$UNAUTH_SUCCESS" == "false" ]]; then
  echo "✅ PASS: MongoDB authentication is properly enabled and working"
  exit 0
elif [[ "$AUTH_ENABLED" == "false" ]]; then
  echo "❌ FAIL: MongoDB authentication is not enabled in configuration"
  exit 1
elif [[ "$UNAUTH_SUCCESS" == "true" ]]; then
  echo "❌ FAIL: MongoDB allows unauthenticated access"
  exit 1
else
  echo "❌ FAIL: Could not determine authentication status"
  exit 1
fi
' \
  --query 'Command.CommandId' --output text)

# Wait for command
log "Waiting for SSM command to complete..."
for i in $(seq 1 30); do
  status=$(aws ssm get-command-invocation \
    --region "$AWS_REGION" \
    --command-id "$cmd_id" \
    --instance-id "$iid" \
    --query 'Status' --output text 2>/dev/null || echo "Pending")
  
  case "$status" in
    Success|Failed|TimedOut|Cancelled) break ;;
    *) sleep 5 ;;
  esac
done

# Get results
inv=$(aws ssm get-command-invocation \
  --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$iid" \
  --output json)

rc=$(jq -r '.ResponseCode' <<<"$inv")
status=$(jq -r '.Status' <<<"$inv")
stdout=$(jq -r '.StandardOutputContent' <<<"$inv")
stderr=$(jq -r '.StandardErrorContent' <<<"$inv")

echo "$stdout"

if [[ "$rc" == "0" ]]; then
  log "PASS: MongoDB auth enabled (unauthenticated access denied)."
  exit 0
else
  log "FAIL: MongoDB auth check failed. SSM Status=$status ResponseCode=$rc"
  if [[ -n "$stderr" && "$stderr" != "null" ]]; then
    log "STDERR:"
    echo "$stderr"
  fi
  exit 1
fi