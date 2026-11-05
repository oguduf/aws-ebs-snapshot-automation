#!/usr/bin/env bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$PROJECT_ROOT/bin"
FIXTURE_DIR="$PROJECT_ROOT/examples"
declare -ag AWS_REGIONS=()
declare -ag INSTANCE_RECORDS=()
declare -ag VOLUME_RECORDS=()
declare -ag PROPOSED_SNAPSHOTS=()
declare -ag CREATED_SNAPSHOTS=()
declare -ag SKIPPED_VOLUMES=()
declare -ag RETENTION_KEEP=()
declare -ag RETENTION_EXPIRED=()
declare -ag RETENTION_PROTECTED=()
declare -ag DELETION_CANDIDATES=()
declare -ag DELETED_SNAPSHOTS=()
declare -ag ERRORS=()
RETENTION_RAN=false

set_defaults() {
  INSTANCE_RECORDS=(); VOLUME_RECORDS=(); PROPOSED_SNAPSHOTS=(); CREATED_SNAPSHOTS=(); SKIPPED_VOLUMES=()
  RETENTION_KEEP=(); RETENTION_EXPIRED=(); RETENTION_PROTECTED=(); DELETION_CANDIDATES=(); DELETED_SNAPSHOTS=(); ERRORS=()
  RETENTION_RAN=false
  AWS_REGIONS=("us-east-1" "us-west-2")
  BACKUP_TAG_KEY="Backup"
  BACKUP_TAG_VALUE="true"
  RETENTION_DAYS=30
  MIN_RECOVERY_POINTS=1
  BACKUP_INTERVAL_HOURS=24
  MANAGED_BY_TAG="aws-ebs-snapshot-automation"
  BACKUP_POLICY_TAG="30-day"
  EXECUTION_MODE="offline"
  DRY_RUN=true
  ALLOW_SNAPSHOT_CREATION=false
  ALLOW_SNAPSHOT_DELETION=false
  REPORT_DIRECTORY="$PROJECT_ROOT/reports"
  LOG_LEVEL="INFO"
  ENVIRONMENT="dev"
  REFERENCE_TIME=""
  ACTION="all"
  OUTPUT=""
  OUTPUT_FORMAT="json"
  CONFIRM_DELETION=""
  EXECUTE=false
  MIN_RECOVERY_POINTS=1
}

json_array() {
  if (($# == 0)); then printf '[]'; return; fi
  printf '%s\n' "$@" | jq -cs 'map(fromjson)'
}

tag_value() {
  local tags=$1 key=$2
  jq -r --arg key "$key" '[.[]? | select(.Key == $key) | .Value][0] // ""' <<<"$tags"
}

error_record() {
  local message=$1 region=${2:-} action=${3:-unknown}
  ERRORS+=("$(jq -cn --arg message "$message" --arg region "$region" --arg action "$action" '{message:$message,region:$region,action:$action}')")
  log_event ERROR "$action" failed "$region" "" "" "" "$message" >&2
}

validate_configuration() {
  local region
  [[ ${#AWS_REGIONS[@]} -gt 0 ]] || { printf 'Configuration error: at least one AWS region is required.\n' >&2; return 2; }
  [[ $RETENTION_DAYS =~ ^[0-9]+$ ]] && (( RETENTION_DAYS > 0 )) || { printf 'Configuration error: RETENTION_DAYS must be a positive integer.\n' >&2; return 2; }
  [[ $BACKUP_INTERVAL_HOURS =~ ^[0-9]+$ ]] && (( BACKUP_INTERVAL_HOURS > 0 && BACKUP_INTERVAL_HOURS <= 8760 )) || { printf 'Configuration error: BACKUP_INTERVAL_HOURS must be 1-8760.\n' >&2; return 2; }
  [[ $MIN_RECOVERY_POINTS =~ ^[0-9]+$ ]] || { printf 'Configuration error: MIN_RECOVERY_POINTS must be a non-negative integer.\n' >&2; return 2; }
  [[ $BACKUP_TAG_KEY =~ ^[A-Za-z0-9_.:/=+@-]{1,128}$ ]] || { printf 'Configuration error: invalid backup tag key.\n' >&2; return 2; }
  [[ -n $BACKUP_TAG_VALUE && ${#BACKUP_TAG_VALUE} -le 256 ]] || { printf 'Configuration error: invalid backup tag value.\n' >&2; return 2; }
  [[ $EXECUTION_MODE == offline || $EXECUTION_MODE == live-discovery || $EXECUTION_MODE == live-snapshot || $EXECUTION_MODE == live-cleanup ]] || { printf 'Configuration error: unsupported execution mode.\n' >&2; return 2; }
  [[ $ACTION == backup || $ACTION == retention || $ACTION == all ]] || { printf 'Configuration error: action must be backup, retention, or all.\n' >&2; return 2; }
  [[ $OUTPUT_FORMAT == json ]] || { printf 'Configuration error: only JSON reporting is supported.\n' >&2; return 2; }
  [[ $ENVIRONMENT == dev || $ENVIRONMENT == stage || $ENVIRONMENT == prod ]] || { printf 'Configuration error: ENVIRONMENT must be dev, stage, or prod.\n' >&2; return 2; }
  [[ -n $MANAGED_BY_TAG && ${#MANAGED_BY_TAG} -le 256 ]] || { printf 'Configuration error: invalid ManagedBy tag value.\n' >&2; return 2; }
  [[ $LOG_LEVEL == DEBUG || $LOG_LEVEL == INFO || $LOG_LEVEL == WARN || $LOG_LEVEL == ERROR ]] || { printf 'Configuration error: invalid log level.\n' >&2; return 2; }
  [[ $DRY_RUN == true || $DRY_RUN == false ]] || { printf 'Configuration error: DRY_RUN must be true or false.\n' >&2; return 2; }
  [[ $ALLOW_SNAPSHOT_CREATION == true || $ALLOW_SNAPSHOT_CREATION == false ]] || { printf 'Configuration error: invalid snapshot creation flag.\n' >&2; return 2; }
  [[ $ALLOW_SNAPSHOT_DELETION == true || $ALLOW_SNAPSHOT_DELETION == false ]] || { printf 'Configuration error: invalid snapshot deletion flag.\n' >&2; return 2; }
  for region in "${AWS_REGIONS[@]}"; do
    [[ $region =~ ^[a-z0-9]+(-[a-z0-9]+)+$ ]] || { printf 'Configuration error: invalid region: %s\n' "$region" >&2; return 2; }
  done
  if [[ -n $REFERENCE_TIME ]] && ! date -u -d "$REFERENCE_TIME" +%s >/dev/null 2>&1; then
    printf 'Configuration error: REFERENCE_TIME must be an ISO-8601 timestamp.\n' >&2; return 2
  fi
  if [[ $EXECUTION_MODE == offline && ( $ALLOW_SNAPSHOT_CREATION == true || $ALLOW_SNAPSHOT_DELETION == true ) ]]; then
    printf 'Configuration error: offline mode cannot enable live mutations.\n' >&2; return 2
  fi
  if [[ $EXECUTION_MODE == live-snapshot && $ACTION == retention ]]; then
    printf 'Configuration error: live-snapshot mode cannot run retention only.\n' >&2; return 2
  fi
  if [[ $EXECUTION_MODE == live-cleanup && $ACTION == backup ]]; then
    printf 'Configuration error: live-cleanup mode cannot run backup only.\n' >&2; return 2
  fi
}

reference_epoch() {
  if [[ -n $REFERENCE_TIME ]]; then date -u -d "$REFERENCE_TIME" +%s; else date -u +%s; fi
}
