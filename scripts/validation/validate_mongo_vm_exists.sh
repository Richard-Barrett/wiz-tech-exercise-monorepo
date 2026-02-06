#!/usr/bin/env bash
set -euo pipefail

id=$(aws ec2 describe-instances \
  --filters "Name=tag:${MONGO_TAG_KEY},Values=${MONGO_TAG_VALUE}" "Name=instance-state-name,Values=running,stopped,pending" \
  --query 'Reservations[].Instances[].InstanceId' --output text)

[[ -n "${id}" && "${id}" != "None" ]] || { echo "No instance found for tag ${MONGO_TAG_KEY}=${MONGO_TAG_VALUE}"; exit 1; }
echo "Mongo VM InstanceId: ${id}"
