#!/usr/bin/env bash
set -euo pipefail

REPORT_MD="validation_report.md"
REPORT_JSON="validation_report.json"

pass_count=0
fail_count=0

# JSON accumulator
json_items=()

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
ok()  { log "✅ $*"; }
bad() { log "❌ $*"; }

record_result () {
  local id="$1" title="$2" status="$3" details="$4"
  json_items+=("{\"id\":\"$id\",\"title\":\"$title\",\"status\":\"$status\",\"details\":$(jq -Rs . <<<"$details")}")
  if [[ "$status" == "PASS" ]]; then
    pass_count=$((pass_count+1))
  else
    fail_count=$((fail_count+1))
  fi
}

run_check () {
  local id="$1" title="$2" cmd="$3"
  log "Running: $title"
  set +e
  out=$(bash -lc "$cmd" 2>&1)
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    ok "$title"
    record_result "$id" "$title" "PASS" "$out"
  else
    bad "$title"
    record_result "$id" "$title" "FAIL" "$out"
  fi
}

# --------- EC2 / Mongo VM checks ---------
run_check "VM01" "Mongo VM exists (by tag)" \
  "bash scripts/validation/validate_mongo_vm_exists.sh"

run_check "VM02" "VM uses 1+ year outdated Linux (heuristic via AMI name / platform)" \
  "bash scripts/validation/validate_vm_outdated_linux.sh"

run_check "VM03" "SSH (22) is exposed to the public internet (0.0.0.0/0)" \
  "bash scripts/validation/validate_ssh_public.sh"

run_check "VM04" "VM role is overly permissive (IAM allows broad EC2 actions)" \
  "bash scripts/validation/validate_vm_iam_overpermissive.sh"

run_check "DB01" "MongoDB version is 1+ year outdated (major version check)" \
  "bash scripts/validation/validate_mongo_version_outdated.sh"

run_check "DB02" "MongoDB access restricted to Kubernetes-only network (SG allows only EKS CIDR / SG)" \
  "bash scripts/validation/validate_mongo_network_restricted.sh"

# run_check "DB03" "MongoDB auth enabled (unauthenticated access denied)" \
#   "bash scripts/validation/validate_mongo_auth_enabled.sh"

run_check "BK01" "Daily backups configured (cron or systemd timer inferred) + recent backup object exists" \
  "bash scripts/validation/validate_backups_present.sh"

# run_check "BK02" "Backup object storage allows public read + public listing" \
#   "bash scripts/validation/validate_s3_public_read_list.sh"

# --------- Kubernetes app checks ---------
run_check "K801" "EKS cluster nodes are in private subnets (no public IPs on nodes)" \
  "bash scripts/validation/validate_eks_private_nodes.sh"

run_check "K802" "App uses MongoDB via env var from Secret (MONGODB_URI present)" \
  "bash scripts/validation/validate_app_env_mongodb_uri.sh"

run_check "K803" "Container contains /app/wizexercise.txt and has expected name" \
  "bash scripts/validation/validate_wizexercise_txt.sh"

run_check "K804" "App SA has cluster-wide admin privileges (clusterrolebinding to cluster-admin)" \
  "bash scripts/validation/validate_cluster_admin_rbac.sh"

run_check "K805" "Ingress exists and fronted by an AWS Load Balancer" \
  "bash scripts/validation/validate_ingress_lb.sh"

run_check "K806" "Web app health endpoint reachable from inside cluster + data proves DB usage" \
  "bash scripts/validation/validate_app_db_roundtrip.sh"

# --------- Write report ---------
{
  echo "# Wiz Exercise Project Validation Report"
  echo
  echo "- Timestamp (UTC): \`$(date -u +%Y-%m-%dT%H:%M:%SZ)\`"
  echo "- Region: \`${AWS_REGION}\`"
  echo "- EKS Cluster: \`${EKS_CLUSTER_NAME}\`"
  echo "- Namespace: \`${K8S_NAMESPACE}\`"
  echo
  echo "## Summary"
  echo "- ✅ Passed: ${pass_count}"
  echo "- ❌ Failed: ${fail_count}"
  echo
  echo "## Details"
  echo
  echo "| ID | Check | Status |"
  echo "|---|---|---|"
  for item in "${json_items[@]}"; do
    id=$(jq -r '.id' <<<"$item")
    title=$(jq -r '.title' <<<"$item")
    status=$(jq -r '.status' <<<"$item")
    echo "| ${id} | ${title} | ${status} |"
  done

  echo
  echo "### Raw Outputs"
  for item in "${json_items[@]}"; do
    id=$(jq -r '.id' <<<"$item")
    title=$(jq -r '.title' <<<"$item")
    status=$(jq -r '.status' <<<"$item")
    details=$(jq -r '.details' <<<"$item")
    echo
    echo "#### ${id} - ${title} (${status})"
    echo '```'
    echo "$details"
    echo '```'
  done
} > "$REPORT_MD"

printf "[%s]\n" "$(IFS=,; echo "${json_items[*]}")" | jq '.' > "$REPORT_JSON"

log "Report written: $REPORT_MD and $REPORT_JSON"

# Fail workflow if any failures
if [[ "$fail_count" -gt 0 ]]; then
  log "One or more checks failed."
  exit 1
fi

log "All checks passed."
