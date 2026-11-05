#!/usr/bin/env bash

declare -ag MANAGED_SNAPSHOTS=()
declare -Ag SNAPSHOT_INVENTORY_ERRORS=()

load_managed_snapshots() {
  MANAGED_SNAPSHOTS=()
  SNAPSHOT_INVENTORY_ERRORS=()
  local region response snapshot managed owner snapshot_id state source created
  for region in "${AWS_REGIONS[@]}"; do
    response=$(aws_request describe-snapshots "$region") || { SNAPSHOT_INVENTORY_ERRORS[$region]=1; error_record "Snapshot inventory failed" "$region" describe-snapshots; continue; }
    if ! validate_response_array "$response" Snapshots; then
      SNAPSHOT_INVENTORY_ERRORS[$region]=1
      error_record "Malformed describe-snapshots response" "$region" describe-snapshots
      continue
    fi
    while IFS= read -r snapshot; do
      [[ -n $snapshot ]] || continue
      managed=$(tag_value "$(jq -c '.Tags // []' <<<"$snapshot")" ManagedBy)
      [[ $managed == "$MANAGED_BY_TAG" ]] || continue
      owner=$(jq -r '.OwnerId // empty' <<<"$snapshot")
      snapshot_id=$(jq -r '.SnapshotId // empty' <<<"$snapshot")
      if [[ -z $owner || ! $snapshot_id =~ ^snap-[a-fA-F0-9]{8}([a-fA-F0-9]{9})?$ ]]; then
        SNAPSHOT_INVENTORY_ERRORS[$region]=1
        error_record "Managed snapshot is missing valid owner or snapshot ID metadata" "$region" describe-snapshots
        continue
      fi
      state=$(jq -r '.State // ""' <<<"$snapshot")
      if [[ $state == completed || $state == pending ]]; then
        source=$(tag_value "$(jq -c '.Tags // []' <<<"$snapshot")" SourceVolumeId)
        created=$(jq -r '.StartTime // empty' <<<"$snapshot")
        if [[ ! $source =~ ^vol-[a-fA-F0-9]{8}([a-fA-F0-9]{9})?$ || -z $created ]] || ! date -u -d "$created" +%s >/dev/null 2>&1; then
          SNAPSHOT_INVENTORY_ERRORS[$region]=1
          error_record "Managed snapshot lacks source-volume or creation-time metadata" "$region" describe-snapshots
        fi
      fi
      MANAGED_SNAPSHOTS+=("$(jq -c --arg region "$region" '. + {Region:$region}' <<<"$snapshot")")
    done < <(jq -c '.Snapshots[]?' <<<"$response")
  done
}

recent_snapshot_for_volume() {
  local volume_id=$1 now cutoff snapshot tags source created
  now=$(reference_epoch)
  cutoff=$((now - BACKUP_INTERVAL_HOURS * 3600))
  for snapshot in "${MANAGED_SNAPSHOTS[@]}"; do
    tags=$(jq -c '.Tags // []' <<<"$snapshot")
    source=$(tag_value "$tags" SourceVolumeId)
    [[ $(jq -r '.State // ""' <<<"$snapshot") == completed || $(jq -r '.State // ""' <<<"$snapshot") == pending ]] || continue
    created=$(jq -r '.StartTime // empty' <<<"$snapshot")
    [[ -n $created ]] || { printf 'invalid_snapshot_metadata\n'; return 2; }
    created=$(date -u -d "$created" +%s 2>/dev/null) || { printf 'invalid_snapshot_metadata\n'; return 2; }
    [[ $source =~ ^vol-[a-fA-F0-9]{8}([a-fA-F0-9]{9})?$ ]] || { printf 'invalid_snapshot_metadata\n'; return 2; }
    [[ $source == "$volume_id" ]] || continue
    if (( created > cutoff )); then jq -r '.SnapshotId' <<<"$snapshot"; return 0; fi
  done
  return 1
}

create_snapshot_for_volume() {
  local record=$1 volume_id instance_id region env description tag_specs response snapshot_id
  volume_id=$(jq -r '.VolumeId' <<<"$record")
  instance_id=$(jq -r '.instance_id' <<<"$record")
  region=$(jq -r '.region' <<<"$record")
  env=$(jq -r '.environment // ""' <<<"$record"); [[ -n $env ]] || env=$ENVIRONMENT
  description="Automated backup for volume ${volume_id} attached to instance ${instance_id}"
  tag_specs=$(jq -cn --arg managed "$MANAGED_BY_TAG" --arg policy "$BACKUP_POLICY_TAG" --arg vol "$volume_id" \
    --arg instance "$instance_id" --arg env "$env" \
    '[{ResourceType:"snapshot",Tags:[{Key:"ManagedBy",Value:$managed},{Key:"BackupPolicy",Value:$policy},{Key:"SourceVolumeId",Value:$vol},{Key:"SourceInstanceId",Value:$instance},{Key:"Environment",Value:$env},{Key:"CreatedBy",Value:"automation"}]}]')
  response=$(aws_request create-snapshot "$region" --volume-id "$volume_id" --description "$description" --tag-specifications "$tag_specs") || {
    error_record "Snapshot creation failed" "$region" create-snapshot
    return 1
  }
  snapshot_id=$(jq -r '.SnapshotId // empty' <<<"$response")
  if [[ ! $snapshot_id =~ ^snap-[a-fA-F0-9]+$ ]]; then
    error_record "CreateSnapshot response omitted a valid snapshot ID" "$region" create-snapshot
    return 1
  fi
  CREATED_SNAPSHOTS+=("$(jq -cn --arg region "$region" --arg volume "$volume_id" --arg instance "$instance_id" --arg snapshot "$snapshot_id" '{region:$region,volume_id:$volume,instance_id:$instance,snapshot_id:$snapshot,result:"created"}')")
  log_event INFO create-snapshot created "$region" "$instance_id" "$volume_id" "$snapshot_id" "Snapshot created with ownership tags"
}

run_backup() {
  local record volume_id region duplicate status
  discover_instances
  discover_volumes
  load_managed_snapshots
  for record in "${VOLUME_RECORDS[@]}"; do
    volume_id=$(jq -r '.VolumeId' <<<"$record")
    region=$(jq -r '.region' <<<"$record")
    if [[ -n ${SNAPSHOT_INVENTORY_ERRORS[$region]+x} ]]; then
      SKIPPED_VOLUMES+=("$(jq -cn --arg vol "$volume_id" --arg region "$region" '{volume_id:$vol,region:$region,result:"skipped_inventory_unavailable"}')")
      continue
    fi
    if duplicate=$(recent_snapshot_for_volume "$volume_id"); then
      SKIPPED_VOLUMES+=("$(jq -cn --arg vol "$volume_id" --arg region "$region" --arg snap "$duplicate" '{volume_id:$vol,region:$region,result:"skipped_recent_duplicate",existing_snapshot_id:$snap}')")
      log_event INFO create-snapshot skipped "$region" "" "$volume_id" "$duplicate" "Backup interval has not elapsed"
      continue
    else
      local duplicate_status=$?
      if (( duplicate_status == 2 )); then
        error_record "Recent managed snapshot has invalid time metadata; refusing duplicate-prone creation" "$region" describe-snapshots
        SKIPPED_VOLUMES+=("$(jq -cn --arg vol "$volume_id" --arg region "$region" '{volume_id:$vol,region:$region,result:"skipped_invalid_snapshot_metadata"}')")
        continue
      fi
    fi
    status=planned
    if [[ $EXECUTION_MODE == live-snapshot && $EXECUTE == true && $DRY_RUN == false && $ALLOW_SNAPSHOT_CREATION == true ]]; then
      if create_snapshot_for_volume "$record"; then status=created; else status=failed; fi
    elif [[ $EXECUTION_MODE != offline ]]; then
      status=discovery_only
    fi
    PROPOSED_SNAPSHOTS+=("$(jq -cn --arg region "$region" --arg vol "$volume_id" --arg instance "$(jq -r '.instance_id' <<<"$record")" --arg status "$status" --arg type "$(jq -r '.VolumeType' <<<"$record")" --argjson size "$(jq -r '.Size' <<<"$record")" '{region:$region,volume_id:$vol,instance_id:$instance,volume_type:$type,size_gib:$size,result:$status}')")
    log_event INFO create-snapshot "$status" "$region" "$(jq -r '.instance_id' <<<"$record")" "$volume_id" "" "Snapshot action: $status"
  done
}
