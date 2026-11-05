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

@test "offline discovery selects only running Backup=true instances and attached EBS volumes" {
  run "$CLI" --mode offline --action backup --fixtures "$ROOT/examples" \
    --reference-time 2026-11-05T12:00:00Z --output "$BATS_TEST_TMPDIR/backup.json"
  [ "$status" -eq 0 ]
  [ "$(jq '.backup.eligible_instances | length' "$BATS_TEST_TMPDIR/backup.json")" -eq 4 ]
  [ "$(jq '.backup.eligible_volumes | length' "$BATS_TEST_TMPDIR/backup.json")" -eq 3 ]
  [ "$(jq '[.backup.eligible_volumes[].VolumeId] | unique | length' "$BATS_TEST_TMPDIR/backup.json")" -eq 3 ]
  [ ! -s "$AWS_CALL_LOG" ]
}

@test "zero matching instances completes safely with empty selections" {
  mkdir -p "$BATS_TEST_TMPDIR/empty"
  cp "$ROOT/examples/volumes.json" "$ROOT/examples/snapshots.json" "$ROOT/examples/images.json" "$ROOT/examples/recyclebin-rules.json" "$BATS_TEST_TMPDIR/empty/"
  printf '{"us-east-1":{"Reservations":[]},"us-west-2":{"Reservations":[]}}\n' >"$BATS_TEST_TMPDIR/empty/instances.json"
  run "$CLI" --mode offline --action backup --fixtures "$BATS_TEST_TMPDIR/empty" --output "$BATS_TEST_TMPDIR/empty-report.json"
  [ "$status" -eq 0 ]
  [ "$(jq '.backup.eligible_instances | length' "$BATS_TEST_TMPDIR/empty-report.json")" -eq 0 ]
  [ "$(jq '.backup.eligible_volumes | length' "$BATS_TEST_TMPDIR/empty-report.json")" -eq 0 ]
}

@test "malformed fixture records an error and exits nonzero without calling AWS" {
  mkdir -p "$BATS_TEST_TMPDIR/malformed"
  cp "$ROOT/examples/volumes.json" "$ROOT/examples/snapshots.json" "$ROOT/examples/images.json" "$ROOT/examples/recyclebin-rules.json" "$BATS_TEST_TMPDIR/malformed/"
  printf '{"us-east-1":{"Reservations":"not-an-array"},"us-west-2":{"Reservations":[]}}\n' >"$BATS_TEST_TMPDIR/malformed/instances.json"
  run "$CLI" --mode offline --action backup --fixtures "$BATS_TEST_TMPDIR/malformed" --output "$BATS_TEST_TMPDIR/malformed-report.json"
  [ "$status" -eq 1 ]
  [ "$(jq '.backup.errors | length' "$BATS_TEST_TMPDIR/malformed-report.json")" -gt 0 ]
  [ ! -s "$AWS_CALL_LOG" ]
}

@test "live discovery uses mocked AWS CLI reads and never mutates resources" {
  printf '{"Reservations":[{"Instances":[{"InstanceId":"i-1111111111111111","State":{"Name":"running"},"Placement":{"AvailabilityZone":"us-east-1a"},"Tags":[{"Key":"Backup","Value":"true"},{"Key":"Environment","Value":"dev"}],"BlockDeviceMappings":[{"Ebs":{"VolumeId":"vol-1111111111111111"}}]}]}]}' >"$BATS_TEST_TMPDIR/instances.json"
  printf '{"Volumes":[{"VolumeId":"vol-1111111111111111","Size":20,"VolumeType":"gp3","Encrypted":true,"State":"in-use","AvailabilityZone":"us-east-1a","Attachments":[{"InstanceId":"i-1111111111111111","State":"attached"}],"Tags":[]}]}' >"$BATS_TEST_TMPDIR/volumes.json"
  printf '{"Snapshots":[]}' >"$BATS_TEST_TMPDIR/snapshots.json"
  export MOCK_INSTANCES_RESPONSE="$BATS_TEST_TMPDIR/instances.json"
  export MOCK_VOLUMES_RESPONSE="$BATS_TEST_TMPDIR/volumes.json"
  export MOCK_SNAPSHOTS_RESPONSE="$BATS_TEST_TMPDIR/snapshots.json"
  run "$CLI" --mode live-discovery --action backup --regions us-east-1 --fixtures "$ROOT/examples" \
    --reference-time 2026-11-05T12:00:00Z --output "$BATS_TEST_TMPDIR/live-discovery.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.backup.snapshots_proposed[0].result' "$BATS_TEST_TMPDIR/live-discovery.json")" = discovery_only ]
  ! grep -q 'create-snapshot\|delete-snapshot' "$AWS_CALL_LOG"
}

@test "AccessDenied and throttling from a mocked read call fail safely" {
  export MOCK_FAIL_OPERATION="ec2 describe-instances"
  export MOCK_AWS_ERROR_CODE=Throttling
  export MOCK_AWS_EXIT_CODE=254
  run "$CLI" --mode live-discovery --action backup --regions us-east-1 --fixtures "$ROOT/examples" \
    --output "$BATS_TEST_TMPDIR/throttled.json"
  [ "$status" -eq 1 ]
  [ "$(jq '.backup.errors | length' "$BATS_TEST_TMPDIR/throttled.json")" -gt 0 ]
  ! grep -q 'create-snapshot\|delete-snapshot' "$AWS_CALL_LOG"
}
