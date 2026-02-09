#!/usr/bin/env bash
set -euo pipefail

iid=$(aws ec2 describe-instances \
  --filters "Name=tag:${MONGO_TAG_KEY},Values=${MONGO_TAG_VALUE}" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

sgs=$(aws ec2 describe-instances --instance-ids "$iid" --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' --output text)

echo "InstanceId: $iid"
echo "SecurityGroups: $sgs"
echo "Mongo port: $MONGO_PORT"

# Determine EKS VPC CIDR(s) from cluster
vpc_id=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --query 'cluster.resourcesVpcConfig.vpcId' --output text)
cidr=$(aws ec2 describe-vpcs --vpc-ids "$vpc_id" --query 'Vpcs[0].CidrBlock' --output text)

echo "EKS VPC: $vpc_id"
echo "EKS VPC CIDR: $cidr"

# Fail if Mongo port is open to 0.0.0.0/0; pass if it is limited to VPC CIDR (or SG refs)
for sg in $sgs; do
  perms=$(aws ec2 describe-security-groups --group-ids "$sg" --output json)
  open_world=$(jq -r --arg port "$MONGO_PORT" '
    .SecurityGroups[0].IpPermissions[]
    | select((.FromPort|tostring)==$port and (.ToPort|tostring)==$port and .IpProtocol=="tcp")
    | .IpRanges[]? | .CidrIp
  ' <<<"$perms" | grep -x "0.0.0.0/0" || true)

  if [[ -n "$open_world" ]]; then
    echo "Mongo port $MONGO_PORT open to world on SG: $sg"
    exit 1
  fi

  # Check if allowed from VPC CIDR
  allowed_vpc=$(jq -r --arg port "$MONGO_PORT" --arg cidr "$cidr" '
    .SecurityGroups[0].IpPermissions[]
    | select((.FromPort|tostring)==$port and (.ToPort|tostring)==$port and .IpProtocol=="tcp")
    | .IpRanges[]? | .CidrIp
  ' <<<"$perms" | grep -x "$cidr" || true)

  if [[ -n "$allowed_vpc" ]]; then
    echo "Mongo port $MONGO_PORT restricted to VPC CIDR on SG: $sg"
    exit 0
  fi

  # Or allowed via SG-to-SG (best-effort)
  sg_refs=$(jq -r --arg port "$MONGO_PORT" '
    .SecurityGroups[0].IpPermissions[]
    | select((.FromPort|tostring)==$port and (.ToPort|tostring)==$port and .IpProtocol=="tcp")
    | .UserIdGroupPairs[]?.GroupId
  ' <<<"$perms" || true)
  if [[ -n "$sg_refs" ]]; then
    echo "Mongo port allowed via SG references on SG: $sg (good for k8s-only access depending on design): $sg_refs"
    exit 0
  fi
done

echo "Could not verify Mongo port restriction to EKS VPC CIDR or SG reference."
exit 1
