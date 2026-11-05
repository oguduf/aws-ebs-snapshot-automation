#!/usr/bin/env bash

declare -Ag PLANNED_RECOVERY_POINT_DELETIONS=()
declare -Ag SUCCESSFUL_RECOVERY_POINT_DELETIONS=()

snapshot_is_protected() {
  local tags=$1
  [[ $(tag_value "$tags" BackupProtected) == true || $(tag_value "$tags" ComplianceHold) == true || \
     $(tag_value "$tags" LegalHold) == true || $(tag_value "$tags" RetentionExempt) == true ]]
}

snapshot_referenced_by_ami() {
  local region=$1 snapshot_id=$2 response
  if [[ $EXECUTION_MODE == offline ]]; then
    response=$(fixture_response images.json "$region") || return 2
  else
    response=$(aws_request describe-images "$region" --filters "Name=block-device-mapping.snapshot-id,Values=${snapshot_id}") || return 2
  fi
  jq -e --arg id "$snapshot_id" 'any(.Images[]?.BlockDeviceMappings[]?.Ebs.SnapshotId?; . == $id)' <<<"$response" >/dev/null
}

snapshot_matches_recycle_bin_rule() {
  local region=$1 snapshot=$2 response tags
  if [[ $EXECUTION_MODE == offline ]]; then
    response=$(fixture_response recyclebin-rules.json "$region") || return 2
  else
    response=$(aws_request list-recycle-bin-rules "$region") || return 2
  fi
  jq -e --argjson snapshot "$snapshot" '
    def matches_tags($required; $actual):
      all($required[]?; . as $r | any($actual[]?; .Key==$r.ResourceTagKey and .Value==$r.ResourceTagValue));
    any(.Rules[]? as $rule
      | ($rule.ResourceType == "EBS_SNAPSHOT")
        and ($rule.Status == "AVAILABLE" or $rule.Status == "ACTIVE" or $rule.Status == null)
        and matches_tags(($rule.ResourceTags // []); ($snapshot.Tags // [])))
  ' <<<"$response" >/dev/null
}

snapshot_complete_metadata() {
  local snapshot=$1 tags source created snapshot_id owner_id
  tags=$(jq -c '.Tags // []' <<<"$snapshot")
  source=$(tag_value "$tags" SourceVolumeId)
  created=$(jq -r '.StartTime // empty' <<<"$snapshot")
  snapshot_id=$(jq -r '.SnapshotId // empty' <<<"$snapshot")
  owner_id=$(jq -r '.OwnerId // empty' <<<"$snapshot")
  [[ $(jq -r '.State // ""' <<<"$snapshot") == completed && $source =~ ^vol-[a-fA-F0-9]{8}([a-fA-F0-9]{9})?$ && $snapshot_id =~ ^snap-[a-fA-F0-9]{8}([a-fA-F0-9]{9})?$ && -n $owner_id && -n $created ]] || return 1
  date -u -d "$created" +%s >/dev/null 2>&1
}

minimum_recovery_points_remaining() {
  local snapshot=$1 source region count key reserved
  source=$(tag_value "$(jq -c '.Tags // []' <<<"$snapshot")" SourceVolumeId)
  region=$(jq -r '.Region' <<<"$snapshot")
  count=0
  local item tags
  for item in "${MANAGED_SNAPSHOTS[@]}"; do
    [[ $(jq -r '.Region' <<<"$item") == "$region" && $(jq -r '.State' <<<"$item") == completed ]] || continue
    tags=$(jq -c '.Tags // []' <<<"$item")
    [[ $(tag_value "$tags" ManagedBy) == "$MANAGED_BY_TAG" && $(tag_value "$tags" SourceVolumeId) == "$source" ]] && ((count+=1))
  done
  key="${region}:${source}"
  if [[ ${RETENTION_PHASE:-scan} == delete ]]; then
    reserved=${SUCCESSFUL_RECOVERY_POINT_DELETIONS[$key]:-0}
  else
    reserved=${PLANNED_RECOVERY_POINT_DELETIONS[$key]:-0}
  fi
  (( count - reserved > MIN_RECOVERY_POINTS ))
}

retention_candidate_is_still_safe() {
  local snapshot_id=$1 region=$2 refreshed snapshot tags owner state
  refreshed=$(aws_request describe-snapshots "$region" --snapshot-ids "$snapshot_id") || return 1
  snapshot=$(jq -ce --arg id "$snapshot_id" --arg region "$region" '.Snapshots[]? | select(.SnapshotId==$id) | . + {Region:$region}' <<<"$refreshed") || return 1
  RECHECKED_SNAPSHOT=$snapshot
  tags=$(jq -c '.Tags // []' <<<"$snapshot")
  owner=$(jq -r '.OwnerId // empty' <<<"$snapshot")
  state=$(jq -r '.State // ""' <<<"$snapshot")
  [[ -n $owner && $(tag_value "$tags" ManagedBy) == "$MANAGED_BY_TAG" && $state == completed ]] || return 1
  ! snapshot_is_protected "$tags"
}

deletion_preflight_is_clear() {
  local snapshot_id=$1 region=$2 ami_status rbin_status
  retention_candidate_is_still_safe "$snapshot_id" "$region" || return 1
  minimum_recovery_points_remaining "$RECHECKED_SNAPSHOT" || return 1
  if snapshot_referenced_by_ami "$region" "$snapshot_id"; then
    return 1
  else
    ami_status=$?
    (( ami_status == 1 )) || return 1
  fi
  if snapshot_matches_recycle_bin_rule "$region" "$RECHECKED_SNAPSHOT"; then
    return 1
  else
    rbin_status=$?
    (( rbin_status == 1 )) || return 1
  fi
}

run_retention() {
  RETENTION_RAN=true
  RETENTION_KEEP=(); RETENTION_EXPIRED=(); RETENTION_PROTECTED=(); DELETION_CANDIDATES=(); DELETED_SNAPSHOTS=()
  PLANNED_RECOVERY_POINT_DELETIONS=(); SUCCESSFUL_RECOVERY_POINT_DELETIONS=(); RETENTION_PHASE=scan
  load_managed_snapshots
  local now cutoff snapshot tags source created created_epoch region snapshot_id why
  now=$(reference_epoch)
  cutoff=$((now - RETENTION_DAYS * 86400))
  local -A seen_ids=()
  for snapshot in "${MANAGED_SNAPSHOTS[@]}"; do
    snapshot_id=$(jq -r '.SnapshotId // empty' <<<"$snapshot")
    region=$(jq -r '.Region' <<<"$snapshot")
    [[ -n $snapshot_id && -z ${seen_ids[$region:$snapshot_id]+x} ]] || continue
    seen_ids[$region:$snapshot_id]=1
    tags=$(jq -c '.Tags // []' <<<"$snapshot")
    if ! snapshot_complete_metadata "$snapshot"; then
      RETENTION_PROTECTED+=("$(jq -cn --arg id "$snapshot_id" --arg region "$region" --arg reason "incomplete_or_invalid_metadata" '{snapshot_id:$id,region:$region,result:"protected",reason:$reason}')")
      continue
    fi
    created=$(jq -r '.StartTime' <<<"$snapshot")
    created_epoch=$(date -u -d "$created" +%s)
    if (( created_epoch >= cutoff )); then
      RETENTION_KEEP+=("$(jq -cn --arg id "$snapshot_id" --arg region "$region" '{snapshot_id:$id,region:$region,result:"within_retention"}')")
      continue
    fi
    RETENTION_EXPIRED+=("$(jq -cn --arg id "$snapshot_id" --arg region "$region" '{snapshot_id:$id,region:$region,result:"expired"}')")
    why=""
    if snapshot_is_protected "$tags"; then
      why=protection_tag
    elif ! minimum_recovery_points_remaining "$snapshot"; then
      why=minimum_recovery_points
    else
      if snapshot_matches_recycle_bin_rule "$region" "$snapshot"; then
        why=recycle_bin_rule_applies_operator_review
      else
        local rbin_status=$?
        if (( rbin_status != 1 )); then
          why=recycle_bin_rule_check_failed
          error_record "Could not determine applicable Recycle Bin rules" "$region" list-recycle-bin-rules
        fi
      fi
    fi
    if [[ -z $why ]]; then
      if snapshot_referenced_by_ami "$region" "$snapshot_id"; then
        why=referenced_by_ami
      else
        local ami_status=$?
        if (( ami_status != 1 )); then
          why=ami_reference_check_failed
          error_record "Could not verify AMI snapshot dependencies" "$region" describe-images
        fi
      fi
    fi
    if [[ -n $why ]]; then
      RETENTION_PROTECTED+=("$(jq -cn --arg id "$snapshot_id" --arg region "$region" --arg reason "$why" '{snapshot_id:$id,region:$region,result:"protected",reason:$reason}')")
      log_event WARN retention protected "$region" "" "" "$snapshot_id" "$why"
      continue
    fi
    DELETION_CANDIDATES+=("$(jq -cn --arg id "$snapshot_id" --arg region "$region" '{snapshot_id:$id,region:$region,result:"deletion_candidate"}')")
    source=$(tag_value "$tags" SourceVolumeId)
    local recovery_key="${region}:${source}"
    PLANNED_RECOVERY_POINT_DELETIONS[$recovery_key]=$(( ${PLANNED_RECOVERY_POINT_DELETIONS[$recovery_key]:-0} + 1 ))
    log_event INFO retention planned "$region" "" "" "$snapshot_id" "Expired managed snapshot is a candidate; approval and governance preflight still apply"
  done
  if [[ $EXECUTION_MODE == live-cleanup && $EXECUTE == true && $DRY_RUN == false && $ALLOW_SNAPSHOT_DELETION == true ]]; then
    RETENTION_PHASE=delete
    local candidate
    for candidate in "${DELETION_CANDIDATES[@]}"; do
      snapshot_id=$(jq -r '.snapshot_id' <<<"$candidate")
      region=$(jq -r '.region' <<<"$candidate")
      if deletion_preflight_is_clear "$snapshot_id" "$region"; then
        if aws_request delete-snapshot "$region" --snapshot-id "$snapshot_id"; then
          DELETED_SNAPSHOTS+=("$(jq -cn --arg id "$snapshot_id" --arg region "$region" '{snapshot_id:$id,region:$region,result:"deleted"}')")
          local source_volume
          source_volume=$(tag_value "$(jq -c '.Tags // []' <<<"$RECHECKED_SNAPSHOT")" SourceVolumeId)
          local deleted_key="${region}:${source_volume}"
          SUCCESSFUL_RECOVERY_POINT_DELETIONS[$deleted_key]=$(( ${SUCCESSFUL_RECOVERY_POINT_DELETIONS[$deleted_key]:-0} + 1 ))
          log_event INFO retention deleted "$region" "" "" "$snapshot_id" "Snapshot deletion accepted by AWS"
        else
          error_record "Snapshot deletion failed; no automatic retry attempted" "$region" delete-snapshot
        fi
      else
        RETENTION_PROTECTED+=("$(jq -cn --arg id "$snapshot_id" --arg region "$region" --arg reason "safety_recheck_failed" '{snapshot_id:$id,region:$region,result:"protected",reason:$reason}')")
        error_record "Snapshot failed deletion safety recheck" "$region" delete-snapshot
      fi
    done
  fi
}
