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
set -euxo pipefail  # Add -x for debugging

echo "=== MongoDB Authentication Check ==="

# Check if MongoDB is running
if ! systemctl is-active --quiet mongod 2>/dev/null; then
  echo "WARNING: MongoDB service is not running or not installed"
  echo "Will check config file anyway..."
fi

echo ""
echo "1. Checking MongoDB configuration..."
CONFIG_FILES="/etc/mongod.conf /etc/mongodb.conf /usr/local/etc/mongod.conf"
FOUND_CONFIG=""
for config in $CONFIG_FILES; do
  if [[ -f "$config" ]]; then
    FOUND_CONFIG="$config"
    break
  fi
done

if [[ -z "$FOUND_CONFIG" ]]; then
  echo "ERROR: Could not find MongoDB config file"
  echo "Searched in: $CONFIG_FILES"
  exit 1
fi

echo "Using config file: $FOUND_CONFIG"

# Extract security section
echo "--- Security section from $FOUND_CONFIG ---"
grep -A5 "^security:" "$FOUND_CONFIG" || echo "No security section found"

# Check for authorization: enabled
AUTH_ENABLED_IN_CONFIG=false
if grep -q "^[[:space:]]*authorization:[[:space:]]*enabled" "$FOUND_CONFIG"; then
  echo "✓ Found 'authorization: enabled' in config"
  AUTH_ENABLED_IN_CONFIG=true
else
  echo "✗ 'authorization: enabled' NOT found in config"
fi

echo ""
echo "2. Testing MongoDB connection..."

# Try to run a command without authentication
TIMEOUT=5
UNAUTH_OUTPUT=""
UNAUTH_SUCCESS=false

# Check which MongoDB client is available
if command -v mongosh >/dev/null 2>&1; then
  CLI="mongosh"
  CLI_ARGS="--quiet --eval"
elif command -v mongo >/dev/null 2>&1; then
  CLI="mongo"
  CLI_ARGS="--quiet --eval"
else
  echo "ERROR: Neither mongosh nor mongo client found"
  echo "Cannot test authentication. Install MongoDB shell tools."
  exit 1
fi

echo "Using client: $CLI"

# Try unauthenticated command with timeout
echo "Attempting unauthenticated ping command..."
if timeout $TIMEOUT bash -c "$CLI $CLI_ARGS \"db.adminCommand({ping: 1})\"" > /tmp/unauth_test.txt 2>&1; then
  UNAUTH_OUTPUT=$(cat /tmp/unauth_test.txt)
  echo "Raw output: '$UNAUTH_OUTPUT'"
  
  if echo "$UNAUTH_OUTPUT" | grep -qi "ok.*1"; then
    UNAUTH_SUCCESS=true
    echo "✗ SECURITY ISSUE: Unauthenticated command SUCCEEDED!"
  else
    echo "✓ Unauthenticated command failed or returned error"
    if echo "$UNAUTH_OUTPUT" | grep -qi "not authorized\|Unauthorized\|auth\|Authentication"; then
      echo "✓ Specifically got authentication error (good!)"
    fi
  fi
else
  TIMEOUT_RC=$?
  UNAUTH_OUTPUT=$(cat /tmp/unauth_test.txt 2>/dev/null || echo "Command failed with code: $TIMEOUT_RC")
  echo "✓ Unauthenticated command failed (as expected)"
  echo "Error output: '$UNAUTH_OUTPUT'"
fi

echo ""
echo "=== Current Status ==="
echo "Config has 'authorization: enabled': $AUTH_ENABLED_IN_CONFIG"
echo "Unauthenticated access succeeds: $UNAUTH_SUCCESS"
echo ""

# Decision logic
if [[ "$UNAUTH_SUCCESS" == "false" ]]; then
  # Unauthenticated access is denied - THIS IS GOOD!
  echo "✅ SUCCESS: Unauthenticated access is properly denied"
  
  if [[ "$AUTH_ENABLED_IN_CONFIG" == "true" ]]; then
    echo "✅ BONUS: 'authorization: enabled' found in config"
  else
    echo "⚠️  WARNING: Auth is working but not explicitly enabled in config"
    echo "   (Might be using alternative auth method or different config)"
  fi
  
  echo ""
  echo "=== FINAL RESULT: PASS ==="
  exit 0
else
  # Unauthenticated access is allowed - THIS IS BAD!
  echo "❌ FAILURE: Unauthenticated access is allowed!"
  echo "   This is a security vulnerability."
  
  if [[ "$AUTH_ENABLED_IN_CONFIG" == "false" ]]; then
    echo "❌ 'authorization: enabled' not found in config"
    echo "   Enable it by adding to $FOUND_CONFIG:"
    echo "   security:"
    echo "     authorization: enabled"
  else
    echo "⚠️  Config has auth enabled but still allows unauth access"
    echo "   Check MongoDB service is actually using this config file"
    echo "   Restart MongoDB after config changes: sudo systemctl restart mongod"
  fi
  
  echo ""
  echo "=== FINAL RESULT: FAIL ==="
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
  
  echo "Check $i/30: SSM Status = $status"
  
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

echo "=== SSM COMMAND OUTPUT ==="
echo "Status: $status"
echo "ResponseCode: $rc"
echo ""
echo "=== STDOUT ==="
echo "$stdout"
echo ""
echo "=== STDERR ==="
echo "$stderr"
echo ""

# Decision based on response code
if [[ "$rc" == "0" ]]; then
  log "✅ PASS: MongoDB authentication check passed"
  exit 0
else
  log "❌ FAIL: MongoDB authentication check failed with RC=$rc"
  
  # Check if failure is because MongoDB isn't running
  if echo "$stdout" | grep -qi "MongoDB service is not running"; then
    log "⚠️  MongoDB service appears to be stopped or not installed"
    log "   Start it with: sudo systemctl start mongod"
    log "   Or install with: sudo apt-get install -y mongodb-org"
  fi
  
  exit 1
fi