#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

: "${AWS_REGION:?}"
: "${BACKUPS_BUCKET:?}"
: "${BACKUPS_PREFIX:?}"

# 1) Public access block can prevent public policies from working
pab=$(aws s3api get-public-access-block \
  --region "$AWS_REGION" \
  --bucket "$BACKUPS_BUCKET" \
  --output json 2>/dev/null || true)

if [[ -n "$pab" ]]; then
  log "PublicAccessBlock:"
  echo "$pab" | jq .
fi

# 2) Bucket policy checks for Principal:"*" grants
policy_json=$(aws s3api get-bucket-policy \
  --region "$AWS_REGION" \
  --bucket "$BACKUPS_BUCKET" \
  --query 'Policy' --output text 2>/dev/null || true)

if [[ -z "${policy_json:-}" || "$policy_json" == "None" ]]; then
  log "FAIL: No bucket policy found on $BACKUPS_BUCKET (cannot prove public read/list)."
  exit 1
fi

policy=$(jq -r '.' <<<"$policy_json")

# Helper: checks if there exists an Allow statement with Principal="*" and Action includes target
has_public_allow() {
  local action="$1"
  jq -e --arg act "$action" --arg b "$BACKUPS_BUCKET" --arg pfx "$BACKUPS_PREFIX" '
    .Statement
    | (if type=="array" then . else [.] end)
    | map(select(.Effect=="Allow"))
    | map(select(
        ( .Principal=="*" or .Principal.AWS=="*" )
        and
        (
          (.Action==$act) or
          ((.Action|type)=="array" and (.Action|index($act)!=null)) or
          (.Action=="s3:*") or
          ((.Action|type)=="array" and (.Action|index("s3:*")!=null))
        )
      ))
    | any(
        # list is against bucket ARN
        ( $act=="s3:ListBucket" and (
            (.Resource=="arn:aws:s3:::\($b)") or
            ((.Resource|type)=="array" and (.Resource|index("arn:aws:s3:::\($b)")!=null))
        ))
        or
        # getobject is against object ARN(s)
        ( $act=="s3:GetObject" and (
            (.Resource=="arn:aws:s3:::\($b)/*") or
            (.Resource=="arn:aws:s3:::\($b)/\($pfx)*") or
            ((.Resource|type)=="array" and (
              (.Resource|index("arn:aws:s3:::\($b)/*")!=null) or
              (.Resource|index("arn:aws:s3:::\($b)/\($pfx)*")!=null)
            ))
        ))
      )
  ' >/dev/null <<<"$policy"
}

list_ok=0
read_ok=0

if has_public_allow "s3:ListBucket"; then
  list_ok=1
fi

if has_public_allow "s3:GetObject"; then
  read_ok=1
fi

log "Bucket policy public listing: $list_ok"
log "Bucket policy public read:    $read_ok"

if [[ "$list_ok" -eq 1 && "$read_ok" -eq 1 ]]; then
  log "PASS: Backup bucket allows public read + public listing (per bucket policy)."
  exit 0
fi

log "FAIL: Could not prove bucket is publicly listable and readable from policy."
log "Tip: Ensure bucket policy has Principal:\"*\" for s3:ListBucket and s3:GetObject."
exit 1
