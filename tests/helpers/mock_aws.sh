#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${AWS_CALL_LOG:?AWS_CALL_LOG is required}"
if [[ ${1:-} == --version ]]; then
  printf 'aws-cli/2.0.0 mock\n'
  exit 0
fi
operation="${1:-} ${2:-}"
if [[ $operation == "${MOCK_FAIL_OPERATION:-__none__}" ]]; then
  printf '{"Error":{"Code":"%s","Message":"synthetic failure"}}\n' "${MOCK_AWS_ERROR_CODE:-AccessDenied}" >&2
  exit "${MOCK_AWS_EXIT_CODE:-255}"
fi
case $operation in
  "ec2 create-snapshot") printf '{"SnapshotId":"snap-f000000000000001"}\n' ;;
  "ec2 describe-instances") cat "${MOCK_INSTANCES_RESPONSE:?}" ;;
  "ec2 describe-volumes") cat "${MOCK_VOLUMES_RESPONSE:?}" ;;
  "ec2 describe-snapshots") cat "${MOCK_SNAPSHOTS_RESPONSE:?}" ;;
  "ec2 describe-images") cat "${MOCK_IMAGES_RESPONSE:?}" ;;
  "rbin list-rules") cat "${MOCK_RECYCLEBIN_RESPONSE:?}" ;;
  *) printf 'Unexpected mocked AWS command: %s\n' "$*" >&2; exit 4 ;;
esac
