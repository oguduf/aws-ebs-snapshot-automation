#!/usr/bin/env bash

discover_instances() {
  INSTANCE_RECORDS=()
  local region response records record
  for region in "${AWS_REGIONS[@]}"; do
    if ! response=$(aws_request describe-instances "$region"); then
      error_record "Instance discovery failed" "$region" describe-instances
      continue
    fi
    if ! jq -e '.Reservations | type == "array"' <<<"$response" >/dev/null; then
      error_record "Malformed describe-instances response" "$region" describe-instances
      continue
    fi
    records=$(jq -c --arg region "$region" --arg key "$BACKUP_TAG_KEY" --arg value "$BACKUP_TAG_VALUE" '
      [.Reservations[]?.Instances[]?
       | select(.State.Name == "running")
       | select(any(.Tags[]?; .Key == $key and .Value == $value))
       | {instance_id:.InstanceId, name:([.Tags[]? | select(.Key=="Name") | .Value][0] // ""),
          region:$region, availability_zone:(.Placement.AvailabilityZone // ""),
          environment:([.Tags[]? | select(.Key=="Environment") | .Value][0] // ""),
          backup_policy:([.Tags[]? | select(.Key=="BackupPolicy") | .Value][0] // ""),
          volume_ids:([.BlockDeviceMappings[]?.Ebs.VolumeId? | select(type=="string" and length>0)] | unique)}]
    ' <<<"$response") || { error_record "Could not parse instance metadata" "$region" describe-instances; continue; }
    while IFS= read -r record; do
      [[ -n $record ]] || continue
      if [[ $(jq -r '.instance_id // empty' <<<"$record") =~ ^i-[a-fA-F0-9]{8}([a-fA-F0-9]{9})?$ ]]; then
        INSTANCE_RECORDS+=("$record")
      else
        error_record "Eligible instance is missing a valid instance ID" "$region" describe-instances
      fi
    done < <(jq -c '.[]' <<<"$records")
    log_event INFO discover-instances complete "$region" "" "" "" "Eligible instances: $(jq 'length' <<<"$records")"
  done
}

discover_volumes() {
  VOLUME_RECORDS=()
  local region instance_json instance_id volume_ids volume_response volume_id volume_json attachment record
  local -A seen=()
  for instance_json in "${INSTANCE_RECORDS[@]}"; do
    region=$(jq -r '.region' <<<"$instance_json")
    instance_id=$(jq -r '.instance_id' <<<"$instance_json")
    volume_ids=$(jq -r '.volume_ids[]?' <<<"$instance_json")
    [[ -n $volume_ids ]] || { log_event INFO discover-volumes skipped "$region" "$instance_id" "" "" "No EBS mappings; instance-store devices are excluded"; continue; }
    local -a ids=()
    while IFS= read -r volume_id; do [[ -n $volume_id ]] && ids+=("$volume_id"); done <<<"$volume_ids"
    if [[ $EXECUTION_MODE == offline ]]; then
      volume_response=$(fixture_response volumes.json "$region") || { error_record "Volume fixture unavailable" "$region" describe-volumes; continue; }
    else
      volume_response=$(aws_request describe-volumes "$region" --volume-ids "${ids[@]}") || { error_record "Volume metadata lookup failed" "$region" describe-volumes; continue; }
    fi
    if ! validate_response_array "$volume_response" Volumes; then
      error_record "Malformed describe-volumes response" "$region" describe-volumes
      continue
    fi
    for volume_id in "${ids[@]}"; do
      if [[ ! $volume_id =~ ^vol-[a-fA-F0-9]{8}([a-fA-F0-9]{9})?$ ]]; then
        error_record "Instance block mapping contains an invalid EBS volume ID" "$region" describe-volumes
        continue
      fi
      [[ -z ${seen[$region:$volume_id]+x} ]] || continue
      seen[$region:$volume_id]=1
      volume_json=$(jq -ce --arg id "$volume_id" '.Volumes[]? | select(.VolumeId == $id)' <<<"$volume_response" 2>/dev/null) || {
        error_record "Attached EBS volume metadata is missing" "$region" describe-volumes
        continue
      }
      attachment=$(jq -c --arg instance "$instance_id" '[.Attachments[]? | select(.InstanceId==$instance and .State=="attached")][0] // empty' <<<"$volume_json")
      if [[ -z $attachment || $(jq -r '.State' <<<"$volume_json") != in-use ]]; then
        error_record "Volume is not confirmed attached to eligible instance" "$region" describe-volumes
        continue
      fi
      if ! jq -e '(.Size|type=="number" and .>0) and (.VolumeType|type=="string" and length>0) and (.Encrypted|type=="boolean")' <<<"$volume_json" >/dev/null; then
        error_record "Volume metadata failed safety validation" "$region" describe-volumes
        continue
      fi
      record=$(jq -cn --argjson instance "$instance_json" --argjson volume "$volume_json" --argjson attachment "$attachment" \
        '$volume + {instance_id:$instance.instance_id,instance_name:$instance.name,region:$instance.region,availability_zone:$volume.AvailabilityZone,environment:($instance.environment // ""),attachment_state:$attachment.State}')
      VOLUME_RECORDS+=("$record")
      log_event INFO discover-volumes eligible "$region" "$instance_id" "$volume_id" "" "Volume verified: $(jq -r '.Size' <<<"$volume_json") GiB $(jq -r '.VolumeType' <<<"$volume_json")"
    done
  done
}
