#!/usr/bin/env bash
set -euo pipefail

iid=$(aws ec2 describe-instances \
  --filters "Name=tag:${MONGO_TAG_KEY},Values=${MONGO_TAG_VALUE}" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

sgs=$(aws ec2 describe-instances --instance-ids "$iid" --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' --output text)

echo "InstanceId: $iid"
echo "SecurityGroups: $sgs"

# Check any SG rule allowing tcp/22 from 0.0.0.0/0
for sg in $sgs; do
  found=$(aws ec2 describe-security-groups --group-ids "$sg" \
    --query "SecurityGroups[0].IpPermissions[?FromPort==\`22\` && ToPort==\`22\` && IpProtocol==\`tcp\`].IpRanges[?CidrIp=='0.0.0.0/0']" \
    --output json)
  if [[ "$(jq 'length' <<<"$found")" -gt 0 ]]; then
    echo "Found public SSH rule on SG: $sg"
    exit 0
  fi
done

echo "No public SSH (22) rule found from 0.0.0.0/0."
exit 1
