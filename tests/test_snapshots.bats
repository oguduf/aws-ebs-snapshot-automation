#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLI="$ROOT/bin/ebs-backup.sh"
  chmod +x "$CLI"
  export AWS_CALL_LOG="$BATS_TEST_TMPDIR/aws-calls.log"
  export MOCK_AWS_MODE=create-snapshot
  mkdir -p "$BATS_TEST_TMPDIR/mockbin"
  cp "$ROOT/tests/helpers/mock_aws.sh" "$BATS_TEST_TMPDIR/mockbin/aws"
  chmod +x "$BATS_TEST_TMPDIR/mockbin/aws"
  export PATH="$BATS_TEST_TMPDIR/mockbin:$PATH"
}

@test "backup interval skips recent volumes and proposes only missing recovery points" {
  run "$CLI" --mode offline --action backup --fixtures "$ROOT/examples" \
    --reference-time 2026-11-05T12:00:00Z --output "$BATS_TEST_TMPDIR/backup.json"
  [ "$status" -eq 0 ]
  [ "$(jq '.backup.snapshots_proposed | length' "$BATS_TEST_TMPDIR/backup.json")" -eq 1 ]
  [ "$(jq '.backup.snapshots_skipped | length' "$BATS_TEST_TMPDIR/backup.json")" -eq 2 ]
  [ "$(jq -r '.backup.snapshots_proposed[0].volume_id' "$BATS_TEST_TMPDIR/backup.json")" = vol-0a222222222222222 ]
  [ ! -s "$AWS_CALL_LOG" ]
}

@test "snapshot tags are attached in the create request when a mocked live client is injected" {
  source "$ROOT/lib/common.sh"
  source "$ROOT/lib/logging.sh"
  source "$ROOT/lib/aws_client.sh"
  source "$ROOT/lib/snapshots.sh"
  set_defaults
  EXECUTION_MODE=live-snapshot
  record='{"VolumeId":"vol-0a222222222222222","instance_id":"i-0a111111111111111","region":"us-east-1","environment":"dev"}'
  create_snapshot_for_volume "$record"
  grep -q 'ManagedBy' "$AWS_CALL_LOG"
  grep -q 'BackupPolicy' "$AWS_CALL_LOG"
  grep -q 'SourceVolumeId' "$AWS_CALL_LOG"
  grep -q 'SourceInstanceId' "$AWS_CALL_LOG"
  grep -q 'Environment' "$AWS_CALL_LOG"
  grep -q 'CreatedBy' "$AWS_CALL_LOG"
  [ "$(jq -r '.snapshot_id' <<<"${CREATED_SNAPSHOTS[0]}")" = snap-f000000000000001 ]
}
