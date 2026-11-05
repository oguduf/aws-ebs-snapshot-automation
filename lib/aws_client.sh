#!/usr/bin/env bash

fixture_response() {
  local file=$1 region=$2 path="$FIXTURE_DIR/$1"
  [[ -r $path ]] || { printf 'Fixture is missing: %s\n' "$path" >&2; return 2; }
  jq -ce --arg region "$region" '.[$region] // error("region fixture is missing")' "$path"
}

aws_request() {
  local operation=$1 region=$2; shift 2
  if [[ $EXECUTION_MODE == offline ]]; then
    case $operation in
      describe-instances) fixture_response instances.json "$region" ;;
      describe-volumes) fixture_response volumes.json "$region" ;;
      describe-snapshots) fixture_response snapshots.json "$region" ;;
      describe-images) fixture_response images.json "$region" ;;
      list-recycle-bin-rules) fixture_response recyclebin-rules.json "$region" ;;
      *) printf 'Offline mode refuses AWS mutation: %s\n' "$operation" >&2; return 90 ;;
    esac
    return
  fi
  command -v aws >/dev/null 2>&1 || { printf 'AWS CLI v2 is required for live modes.\n' >&2; return 127; }
  case $operation in
    describe-instances)
      AWS_RETRY_MODE=standard AWS_MAX_ATTEMPTS=4 aws ec2 describe-instances --region "$region" \
        --filters "Name=instance-state-name,Values=running" "Name=tag:${BACKUP_TAG_KEY},Values=${BACKUP_TAG_VALUE}" --output json "$@" ;;
    describe-volumes)
      AWS_RETRY_MODE=standard AWS_MAX_ATTEMPTS=4 aws ec2 describe-volumes --region "$region" --output json "$@" ;;
    describe-snapshots)
      AWS_RETRY_MODE=standard AWS_MAX_ATTEMPTS=4 aws ec2 describe-snapshots --region "$region" --owner-ids self \
        --filters "Name=tag:ManagedBy,Values=${MANAGED_BY_TAG}" --output json "$@" ;;
    list-recycle-bin-rules)
      AWS_RETRY_MODE=standard AWS_MAX_ATTEMPTS=4 aws rbin list-rules --region "$region" --resource-type EBS_SNAPSHOT --output json "$@" ;;
    describe-images)
      AWS_RETRY_MODE=standard AWS_MAX_ATTEMPTS=4 aws ec2 describe-images --region "$region" --owners self --output json "$@" ;;
    create-snapshot)
      AWS_MAX_ATTEMPTS=1 aws ec2 create-snapshot --region "$region" --output json "$@" ;;
    delete-snapshot)
      AWS_MAX_ATTEMPTS=1 aws ec2 delete-snapshot --region "$region" --output json "$@" ;;
    *) printf 'Unsupported AWS operation: %s\n' "$operation" >&2; return 2 ;;
  esac
}

validate_response_array() {
  local json=$1 key=$2
  jq -e --arg key "$key" 'type == "object" and (.[$key] | type == "array")' <<<"$json" >/dev/null
}
