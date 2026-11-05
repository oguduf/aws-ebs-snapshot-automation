#!/usr/bin/env bash

log_event() {
  local level=$1 action=$2 result=$3 region=${4:-} instance_id=${5:-} volume_id=${6:-} snapshot_id=${7:-} message=${8:-}
  local allowed=0
  case "${LOG_LEVEL:-INFO}:$level" in
    DEBUG:*) allowed=1 ;;
    INFO:INFO|INFO:WARN|INFO:ERROR) allowed=1 ;;
    WARN:WARN|WARN:ERROR) allowed=1 ;;
    ERROR:ERROR) allowed=1 ;;
  esac
  (( allowed == 1 )) || return 0
  jq -cn \
    --arg timestamp "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --arg level "$level" --arg action "$action" --arg result "$result" \
    --arg region "$region" --arg instance_id "$instance_id" \
    --arg volume_id "$volume_id" --arg snapshot_id "$snapshot_id" \
    --arg message "$message" \
    '{timestamp:$timestamp,level:$level,action:$action,result:$result,region:$region,instance_id:$instance_id,volume_id:$volume_id,snapshot_id:$snapshot_id,message:$message}'
}
