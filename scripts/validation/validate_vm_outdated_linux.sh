#!/usr/bin/env bash
set -euo pipefail

iid=$(aws ec2 describe-instances \
  --filters "Name=tag:${MONGO_TAG_KEY},Values=${MONGO_TAG_VALUE}" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

ami=$(aws ec2 describe-instances --instance-ids "$iid" --query 'Reservations[0].Instances[0].ImageId' --output text)
name=$(aws ec2 describe-images --image-ids "$ami" --query 'Images[0].Name' --output text)

echo "InstanceId: $iid"
echo "AMI: $ami"
echo "AMI Name: $name"

# Very generic heuristic: look for Ubuntu 18.04 / Amazon Linux 2 / etc.
# Customize if you know the AMI you used.
if echo "$name" | grep -Eqi '(ubuntu/images/hvm-ssd/ubuntu-bionic|18\.04|amzn2|amazon-linux-2|centos-7)'; then
  echo "Heuristic suggests OS is >= 1 year outdated (based on AMI name)."
  exit 0
fi

echo "Could not confirm outdated OS from AMI name. Update this heuristic for your AMI naming."
exit 1
