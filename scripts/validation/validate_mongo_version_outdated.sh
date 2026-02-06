#!/usr/bin/env bash
set -euo pipefail

# We can't SSH in CI unless you provide a key + public IP.
# Instead, we infer from your userdata/template choices:
# - if you installed MongoDB 5.0 explicitly, that is outdated.
# Adapt if you store the version elsewhere.

# Heuristic: search terraform templates in repo for mongodb-org/5.0
if grep -R --line-number -E "mongodb-org/5\.0|server-5\.0" infra/terraform/userdata 2>/dev/null; then
  echo "Detected MongoDB 5.0 install configuration (outdated)."
  exit 0
fi

echo "Could not detect MongoDB version from repo templates. Add a tag or output and update this check."
exit 1
