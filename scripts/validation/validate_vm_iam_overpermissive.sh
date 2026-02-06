#!/usr/bin/env bash
set -euo pipefail

# What we consider "overly permissive" for this exercise:
# - ec2:RunInstances OR ec2:* OR ec2:Create* allowed on Resource "*"
# - (optional but common) iam:PassRole on "*"
REQUIRED_EC2_ACTIONS_REGEX='^(ec2:\*|ec2:RunInstances|ec2:Create.*)$'
OPTIONAL_PASSROLE_REGEX='^(iam:PassRole|iam:\*)$'

iid=$(aws ec2 describe-instances \
  --filters "Name=tag:${MONGO_TAG_KEY},Values=${MONGO_TAG_VALUE}" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

profile_arn=$(aws ec2 describe-instances --instance-ids "$iid" \
  --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text)

if [[ -z "${profile_arn:-}" || "$profile_arn" == "None" ]]; then
  echo "No instance profile attached; cannot satisfy 'overly permissive CSP permissions'."
  exit 1
fi

profile_name="${profile_arn##*/}"
role_name=$(aws iam get-instance-profile --instance-profile-name "$profile_name" \
  --query 'InstanceProfile.Roles[0].RoleName' --output text)

echo "InstanceId: $iid"
echo "Instance profile: $profile_name"
echo "Role: $role_name"

policy_allows_action_on_star() {
  local policy_doc_json="$1"
  local action_regex="$2"

  # Normalize Action and Resource to arrays; look for Effect=Allow + matching Action + Resource="*"
  jq -e --arg re "$action_regex" '
    .Statement
    | (if type=="array" then . else [.] end)
    | map(select(.Effect=="Allow"))
    | map(
        .Action as $a
        | .Resource as $r
        | {
            actions: (if ($a|type)=="array" then $a else [$a] end),
            resources: (if ($r|type)=="array" then $r else [$r] end)
          }
      )
    | any(
        (.actions | any(test($re)))
        and
        (.resources | index("*") != null)
      )
  ' >/dev/null <<<"$policy_doc_json"
}

found_ec2=0
found_passrole=0

# 1) Check inline policies
inline_names=$(aws iam list-role-policies --role-name "$role_name" --query 'PolicyNames[]' --output text || true)
for pname in $inline_names; do
  doc=$(aws iam get-role-policy --role-name "$role_name" --policy-name "$pname" --query 'PolicyDocument' --output json)
  if policy_allows_action_on_star "$doc" "$REQUIRED_EC2_ACTIONS_REGEX"; then
    echo "✅ Inline policy '$pname' allows VM creation-like EC2 permissions on *"
    found_ec2=1
  fi
  if policy_allows_action_on_star "$doc" "$OPTIONAL_PASSROLE_REGEX"; then
    echo "ℹ️ Inline policy '$pname' allows iam:PassRole on *"
    found_passrole=1
  fi
done

# 2) Check attached managed policies (AWS-managed + customer-managed)
attached_arns=$(aws iam list-attached-role-policies --role-name "$role_name" --query 'AttachedPolicies[].PolicyArn' --output text || true)

for arn in $attached_arns; do
  # Fetch default version document
  default_ver=$(aws iam get-policy --policy-arn "$arn" --query 'Policy.DefaultVersionId' --output text)
  vdoc=$(aws iam get-policy-version --policy-arn "$arn" --version-id "$default_ver" --query 'PolicyVersion.Document' --output json)

  if policy_allows_action_on_star "$vdoc" "$REQUIRED_EC2_ACTIONS_REGEX"; then
    echo "✅ Managed policy '$arn' allows VM creation-like EC2 permissions on *"
    found_ec2=1
  fi
  if policy_allows_action_on_star "$vdoc" "$OPTIONAL_PASSROLE_REGEX"; then
    echo "ℹ️ Managed policy '$arn' allows iam:PassRole on *"
    found_passrole=1
  fi
done

if [[ "$found_ec2" -eq 1 ]]; then
  echo "PASS: Role has overly permissive CSP permissions (can create VMs via EC2)."
  # If you want to REQUIRE passrole too, flip this into a hard requirement.
  exit 0
fi

echo "FAIL: Could not prove VM creation-like EC2 permissions on *."
echo "Tip: Ensure the instance role allows ec2:RunInstances (and often iam:PassRole)."
exit 1
