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

@test "repeated offline runs at a fixed reference timestamp are deterministic" {
  run "$CLI" --mode offline --action all --fixtures "$ROOT/examples" --reference-time 2026-11-05T12:00:00Z --output "$BATS_TEST_TMPDIR/first.json"
  [ "$status" -eq 0 ]
  cp "$ROOT/reports/backup-summary.json" "$BATS_TEST_TMPDIR/backup-first.json"
  cp "$ROOT/reports/retention-summary.json" "$BATS_TEST_TMPDIR/retention-first.json"
  run "$CLI" --mode offline --action all --fixtures "$ROOT/examples" --reference-time 2026-11-05T12:00:00Z --output "$BATS_TEST_TMPDIR/second.json"
  [ "$status" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/backup-first.json" "$ROOT/reports/backup-summary.json"
  cmp "$BATS_TEST_TMPDIR/retention-first.json" "$ROOT/reports/retention-summary.json"
  [ ! -s "$AWS_CALL_LOG" ]
}
