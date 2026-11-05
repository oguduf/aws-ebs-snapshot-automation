#!/usr/bin/env bash

write_json_file() {
  local path=$1 content=$2 parent temp
  parent=$(dirname "$path")
  mkdir -p -- "$parent"
  temp=$(mktemp "$parent/.report.XXXXXX")
  printf '%s\n' "$content" >"$temp"
  chmod 600 "$temp"
  mv -f -- "$temp" "$path"
}

build_backup_report() {
  local timestamp regions instances volumes proposed created skipped errors
  timestamp=$(date -u -d "@$(reference_epoch)" +'%Y-%m-%dT%H:%M:%SZ')
  regions=$(printf '%s\n' "${AWS_REGIONS[@]}" | jq -Rsc 'split("\n") | map(select(length>0))')
  instances=$(json_array "${INSTANCE_RECORDS[@]}")
  volumes=$(json_array "${VOLUME_RECORDS[@]}")
  proposed=$(json_array "${PROPOSED_SNAPSHOTS[@]}")
  created=$(json_array "${CREATED_SNAPSHOTS[@]}")
  skipped=$(json_array "${SKIPPED_VOLUMES[@]}")
  errors=$(json_array "${ERRORS[@]}")
  jq -cn --arg ts "$timestamp" --arg mode "$EXECUTION_MODE" --argjson regions "$regions" \
    --argjson instances "$instances" --argjson volumes "$volumes" --argjson proposed "$proposed" \
    --argjson created "$created" --argjson skipped "$skipped" --argjson errors "$errors" \
    '{execution_timestamp:$ts,execution_mode:$mode,regions_evaluated:$regions,eligible_instances:$instances,eligible_volumes:$volumes,snapshots_proposed:$proposed,snapshots_created:$created,snapshots_skipped:$skipped,errors:$errors,mutations_executed:($created|length>0)}'
}

build_retention_report() {
  local timestamp keep expired protected candidates deleted errors
  timestamp=$(date -u -d "@$(reference_epoch)" +'%Y-%m-%dT%H:%M:%SZ')
  keep=$(json_array "${RETENTION_KEEP[@]}")
  expired=$(json_array "${RETENTION_EXPIRED[@]}")
  protected=$(json_array "${RETENTION_PROTECTED[@]}")
  candidates=$(json_array "${DELETION_CANDIDATES[@]}")
  deleted=$(json_array "${DELETED_SNAPSHOTS[@]}")
  errors=$(json_array "${ERRORS[@]}")
  local evaluated=0
  if [[ $RETENTION_RAN == true ]]; then evaluated=${#MANAGED_SNAPSHOTS[@]}; fi
  jq -cn --arg ts "$timestamp" --arg mode "$EXECUTION_MODE" --argjson evaluated "$evaluated" \
    --argjson keep "$keep" --argjson expired "$expired" --argjson protected "$protected" \
    --argjson candidates "$candidates" --argjson deleted "$deleted" --argjson errors "$errors" \
    '{execution_timestamp:$ts,execution_mode:$mode,managed_snapshots_evaluated:$evaluated,snapshots_within_retention:$keep,expired_snapshots:$expired,protected_snapshots:$protected,deletion_candidates:$candidates,snapshots_deleted:$deleted,errors:$errors,mutations_executed:($deleted|length>0)}'
}

write_reports() {
  local backup retention combined
  backup=$(build_backup_report)
  retention=$(build_retention_report)
  write_json_file "$REPORT_DIRECTORY/backup-summary.json" "$backup"
  write_json_file "$REPORT_DIRECTORY/retention-summary.json" "$retention"
  combined=$(jq -cn --argjson backup "$backup" --argjson retention "$retention" '{backup:$backup,retention:$retention}')
  if [[ -n $OUTPUT ]]; then
    write_json_file "$OUTPUT" "$combined"
    printf 'Wrote combined report to %s\n' "$OUTPUT"
  else
    printf '%s\n' "$combined"
  fi
}
