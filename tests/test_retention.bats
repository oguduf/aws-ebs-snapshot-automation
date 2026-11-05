#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLI="$ROOT/bin/ebs-backup.sh"
  chmod +x "$CLI"
  export AWS_CALL_LOG="$BATS_TEST_TMPDIR/aws-calls.log"
  mkdir -p "$BATS_TEST_TMPDIR/mockbin"
  cp "$ROOT/tests/helpers/mock_aws.sh" "$BATS_TEST_TMPDIR/mockbin/aws"
  chmod +x "$BATS_TEST_TMPDIR/mockbin/aws"
  export PATH="$BATS_TEST_TMPDIR/mockbin:$PATH"
}

@test "retention separates keep, protected and deletion candidates" {
  run "$CLI" --mode offline --action retention --fixtures "$ROOT/examples" \
    --retention-days 30 --reference-time 2026-11-05T12:00:00Z --output "$BATS_TEST_TMPDIR/retention.json"
  [ "$status" -eq 0 ]
  [ "$(jq '.retention.managed_snapshots_evaluated' "$BATS_TEST_TMPDIR/retention.json")" -eq 7 ]
  [ "$(jq '.retention.snapshots_within_retention | length' "$BATS_TEST_TMPDIR/retention.json")" -eq 2 ]
  [ "$(jq '.retention.expired_snapshots | length' "$BATS_TEST_TMPDIR/retention.json")" -eq 5 ]
  [ "$(jq '.retention.protected_snapshots | length' "$BATS_TEST_TMPDIR/retention.json")" -eq 3 ]
  [ "$(jq '.retention.deletion_candidates | length' "$BATS_TEST_TMPDIR/retention.json")" -eq 2 ]
  [ "$(jq '.retention.snapshots_deleted | length' "$BATS_TEST_TMPDIR/retention.json")" -eq 0 ]
  [ "$(jq -r '.retention.protected_snapshots[] | select(.snapshot_id=="snap-0a222222222222222") | .reason' "$BATS_TEST_TMPDIR/retention.json")" = referenced_by_ami ]
  [ ! -s "$AWS_CALL_LOG" ]
}

@test "snapshot exactly at retention boundary remains in retention" {
  mkdir -p "$BATS_TEST_TMPDIR/boundary"
  cp "$ROOT/examples/instances.json" "$ROOT/examples/volumes.json" "$ROOT/examples/images.json" "$ROOT/examples/recyclebin-rules.json" "$BATS_TEST_TMPDIR/boundary/"
  jq '."us-east-1".Snapshots=[{"SnapshotId":"snap-0b111111111111111","VolumeId":"vol-0b111111111111111","OwnerId":"111122223333","State":"completed","StartTime":"2026-10-06T12:00:00Z","Tags":[{"Key":"ManagedBy","Value":"aws-ebs-snapshot-automation"},{"Key":"SourceVolumeId","Value":"vol-0b111111111111111"}]}] | ."us-west-2".Snapshots=[]' "$ROOT/examples/snapshots.json" >"$BATS_TEST_TMPDIR/boundary/snapshots.json"
  run "$CLI" --mode offline --action retention --fixtures "$BATS_TEST_TMPDIR/boundary" \
    --reference-time 2026-11-05T12:00:00Z --output "$BATS_TEST_TMPDIR/boundary.json"
  [ "$status" -eq 0 ]
  [ "$(jq '.retention.snapshots_within_retention | length' "$BATS_TEST_TMPDIR/boundary.json")" -eq 1 ]
  [ "$(jq '.retention.deletion_candidates | length' "$BATS_TEST_TMPDIR/boundary.json")" -eq 0 ]
}

@test "retention preserves the configured minimum recovery-point count" {
  mkdir -p "$BATS_TEST_TMPDIR/minimum"
  cp "$ROOT/examples/instances.json" "$ROOT/examples/volumes.json" "$ROOT/examples/images.json" "$ROOT/examples/recyclebin-rules.json" "$BATS_TEST_TMPDIR/minimum/"
  jq '."us-east-1".Snapshots=[
    {"SnapshotId":"snap-0c111111111111111","VolumeId":"vol-0c111111111111111","OwnerId":"111122223333","State":"completed","StartTime":"2026-09-01T00:00:00Z","Tags":[{"Key":"ManagedBy","Value":"aws-ebs-snapshot-automation"},{"Key":"SourceVolumeId","Value":"vol-0c111111111111111"}]},
    {"SnapshotId":"snap-0c222222222222222","VolumeId":"vol-0c111111111111111","OwnerId":"111122223333","State":"completed","StartTime":"2026-09-02T00:00:00Z","Tags":[{"Key":"ManagedBy","Value":"aws-ebs-snapshot-automation"},{"Key":"SourceVolumeId","Value":"vol-0c111111111111111"}]}
  ] | ."us-west-2".Snapshots=[]' "$ROOT/examples/snapshots.json" >"$BATS_TEST_TMPDIR/minimum/snapshots.json"
  run "$CLI" --mode offline --action retention --fixtures "$BATS_TEST_TMPDIR/minimum" \
    --reference-time 2026-11-05T12:00:00Z --output "$BATS_TEST_TMPDIR/minimum-report.json"
  [ "$status" -eq 0 ]
  [ "$(jq '.retention.deletion_candidates | length' "$BATS_TEST_TMPDIR/minimum-report.json")" -eq 1 ]
  [ "$(jq '[.retention.protected_snapshots[] | select(.reason=="minimum_recovery_points")] | length' "$BATS_TEST_TMPDIR/minimum-report.json")" -eq 1 ]
}

@test "matching Recycle Bin rule blocks a deletion proposal for review" {
  mkdir -p "$BATS_TEST_TMPDIR/recyclebin"
  cp "$ROOT/examples/instances.json" "$ROOT/examples/volumes.json" "$ROOT/examples/snapshots.json" "$ROOT/examples/images.json" "$BATS_TEST_TMPDIR/recyclebin/"
  jq '."us-east-1".Rules=[{"ResourceType":"EBS_SNAPSHOT","Status":"AVAILABLE","ResourceTags":[{"ResourceTagKey":"ManagedBy","ResourceTagValue":"aws-ebs-snapshot-automation"}]}]' "$ROOT/examples/recyclebin-rules.json" >"$BATS_TEST_TMPDIR/recyclebin/recyclebin-rules.json"
  run "$CLI" --mode offline --action retention --fixtures "$BATS_TEST_TMPDIR/recyclebin" \
    --reference-time 2026-11-05T12:00:00Z --output "$BATS_TEST_TMPDIR/recyclebin-report.json"
  [ "$status" -eq 0 ]
  [ "$(jq '[.retention.protected_snapshots[] | select(.reason=="recycle_bin_rule_applies_operator_review")] | length' "$BATS_TEST_TMPDIR/recyclebin-report.json")" -gt 0 ]
}
