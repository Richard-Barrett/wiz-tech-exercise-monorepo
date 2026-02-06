#!/usr/bin/env bash
set -euo pipefail

iid=$(aws ec2 describe-instances \
  --filters "Name=tag:${MONGO_TAG_KEY},Values=${MONGO_TAG_VALUE}" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

profile_arn=$(aws ec2 describe-instances --instance-ids "$iid" \
  --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text)

if [[ -z "$profile_arn" || "$profile_arn" == "None" ]]; then
  echo "No instance profile attached; cannot be overly permissive."
  exit 1
fi

profile_name="${profile_arn##*/}"
role_name=$(aws iam get-instance-profile --instance-profile-name "$profile_name" \
  --query 'InstanceProfile.Roles[0].RoleName' --output text)

echo "Instance profile: $profile_name"
echo "Role: $role_name"

# List attached policies and look for AdministratorAccess or broad EC2 policies
pols=$(aws iam list-attached-role-policies --role-name "$role_name" --output json)
echo "$pols" | jq -r '.AttachedPolicies[].PolicyArn'

if echo "$pols" | jq -r '.AttachedPolicies[].PolicyArn' | grep -Eqi '(AdministratorAccess|PowerUserAccess)'; then
  echo "Role has Admin/PowerUser access."
  exit 0
fi

# Look for any policy with 'ec2:*' and 'Resource:*' (inline policies)
inline=$(aws iam list-role-policies --role-name "$role_name" --query 'PolicyNames[]' --output text || true)
for p in $inline; do
  doc=$(aws iam get-role-policy --role-name "$role_name" --policy-name "$p" --output json)
  if echo "$doc" | jq -e '.PolicyDocument.Statement[] | select((.Action=="ec2:*" or (.Action|type=="array" and (index("ec2:*")!=null))) and (.Resource=="*" or (.Resource|type=="array" and (index("*")!=null))))' >/dev/null; then
    echo "Inline policy '$p' appears overly permissive (ec2:* on *)."
    exit 0
  fi
done

echo "Could not prove overly permissive permissions. If you used a custom policy, adjust this check."
exit 1
