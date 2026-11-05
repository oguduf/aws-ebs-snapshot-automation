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

@test "offline default does not invoke AWS and reports no completed mutations" {
  run "$CLI" --fixtures "$ROOT/examples" --reference-time 2026-11-05T12:00:00Z --output "$BATS_TEST_TMPDIR/all.json"
  [ "$status" -eq 0 ]
  [ "$(jq '[.backup.mutations_executed,.retention.mutations_executed] | all(. == false)' "$BATS_TEST_TMPDIR/all.json")" = true ]
  [ ! -s "$AWS_CALL_LOG" ]
}

@test "live cleanup rejects missing explicit gates before AWS CLI invocation" {
  run "$CLI" --mode live-cleanup --action retention --fixtures "$ROOT/examples"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Safety error"* ]]
  [ ! -s "$AWS_CALL_LOG" ]
}

@test "configuration parser does not execute shell expressions" {
  marker="$BATS_TEST_TMPDIR/should-not-exist"
  printf 'AWS_REGIONS=("us-east-1" "$(touch %s)")\n' "$marker" >"$BATS_TEST_TMPDIR/untrusted.conf"
  source "$ROOT/lib/common.sh"
  source "$ROOT/lib/config.sh"
  set_defaults
  run load_config_file "$BATS_TEST_TMPDIR/untrusted.conf"
  [ "$status" -eq 0 ]
  [ ! -e "$marker" ]
  [ "${#AWS_REGIONS[@]}" -eq 1 ]
}

@test "invalid negative retention period is rejected" {
  run "$CLI" --retention-days -1
  [ "$status" -eq 2 ]
  [[ "$output" == *"RETENTION_DAYS"* ]]
  [ ! -s "$AWS_CALL_LOG" ]
}
