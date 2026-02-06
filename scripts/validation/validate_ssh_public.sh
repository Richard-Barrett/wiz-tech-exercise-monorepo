#!/usr/bin/env bash
set -euo pipefail

: "${MONGO_TAG_KEY:?Must set MONGO_TAG_KEY}"
: "${MONGO_TAG_VALUE:?Must set MONGO_TAG_VALUE}"

# Find *running* instance by tag (pick the first running match deterministically)
iid="$(aws ec2 describe-instances \
  --filters \
    "Name=instance-state-name,Values=running" \
    "Name=tag:${MONGO_TAG_KEY},Values=${MONGO_TAG_VALUE}" \
  --query 'Reservations[].Instances[].InstanceId | [0]' \
  --output text)"

if [[ -z "$iid" || "$iid" == "None" ]]; then
  echo "No running instance found with tag ${MONGO_TAG_KEY}=${MONGO_TAG_VALUE}"
  exit 1
fi

sgs="$(aws ec2 describe-instances \
  --instance-ids "$iid" \
  --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' \
  --output text)"

echo "InstanceId: $iid"
echo "SecurityGroups: $sgs"

# Helper: return 0 if SG has a public SSH-like rule
sg_allows_public_ssh() {
  local sg="$1"

  # Query matches ANY of:
  # 1) tcp 22 exactly
  # 2) tcp 0-65535 (all tcp ports)
  # 3) -1 (all protocols) which implies all ports
  #
  # And source includes 0.0.0.0/0 OR ::/0
  local matches
  matches="$(aws ec2 describe-security-groups --group-ids "$sg" --output json | jq -r '
    .SecurityGroups[0].IpPermissions[]
    | select(
        (.IpProtocol == "tcp" and (
            (.FromPort == 22 and .ToPort == 22) or
            (.FromPort == 0 and .ToPort == 65535)
        )) or
        (.IpProtocol == "-1")
      )
    | (
        (.IpRanges[]?.CidrIp == "0.0.0.0/0") or
        (.Ipv6Ranges[]?.CidrIpv6 == "::/0")
      )
    ' | grep -c true || true)"

  [[ "$matches" -gt 0 ]]
}

for sg in $sgs; do
  if sg_allows_public_ssh "$sg"; then
    echo "Found public SSH exposure on SG: $sg (22 or broader)"
    exit 0
  fi
done

echo "No public SSH exposure found (0.0.0.0/0 or ::/0)."
exit 1
