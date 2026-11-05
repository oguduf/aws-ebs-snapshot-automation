#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_ROOT/lib/common.sh"
# shellcheck source=../lib/logging.sh
source "$SCRIPT_ROOT/lib/logging.sh"
# shellcheck source=../lib/config.sh
source "$SCRIPT_ROOT/lib/config.sh"
# shellcheck source=../lib/aws_client.sh
source "$SCRIPT_ROOT/lib/aws_client.sh"
# shellcheck source=../lib/discovery.sh
source "$SCRIPT_ROOT/lib/discovery.sh"
# shellcheck source=../lib/snapshots.sh
source "$SCRIPT_ROOT/lib/snapshots.sh"
# shellcheck source=../lib/retention.sh
source "$SCRIPT_ROOT/lib/retention.sh"
# shellcheck source=../lib/reporting.sh
source "$SCRIPT_ROOT/lib/reporting.sh"

set_defaults
parse_arguments "$@"
validate_configuration

case $EXECUTION_MODE in
  offline)
    [[ $EXECUTE == false && $DRY_RUN == true && $ALLOW_SNAPSHOT_CREATION == false && $ALLOW_SNAPSHOT_DELETION == false ]] || {
      printf 'Safety error: offline mode cannot execute or enable mutations.\n' >&2; exit 2;
    }
    ;;
  live-discovery)
    [[ $EXECUTE == false && $DRY_RUN == true && $ALLOW_SNAPSHOT_CREATION == false && $ALLOW_SNAPSHOT_DELETION == false ]] || {
      printf 'Safety error: live-discovery is read-only.\n' >&2; exit 2;
    }
    ;;
  live-snapshot)
    [[ $EXECUTE == true && $DRY_RUN == false && $ALLOW_SNAPSHOT_CREATION == true && $ALLOW_SNAPSHOT_DELETION == false ]] || {
      printf 'Safety error: live-snapshot requires --execute and --allow-snapshot-creation, and rejects deletion permission.\n' >&2; exit 2;
    }
    ;;
  live-cleanup)
    [[ $EXECUTE == true && $DRY_RUN == false && $ALLOW_SNAPSHOT_DELETION == true && $ALLOW_SNAPSHOT_CREATION == false && $CONFIRM_DELETION == DELETE-MANAGED-EBS-SNAPSHOTS && ${AWS_EBS_CLEANUP_APPROVED:-false} == true ]] || {
      printf 'Safety error: live-cleanup requires --execute, --allow-snapshot-deletion, --confirm-deletion DELETE-MANAGED-EBS-SNAPSHOTS, and AWS_EBS_CLEANUP_APPROVED=true.\n' >&2; exit 2;
    }
    ;;
esac

if [[ $EXECUTION_MODE != offline ]]; then
  command -v aws >/dev/null 2>&1 || { printf 'AWS CLI v2 is required for live modes.\n' >&2; exit 127; }
  aws_version=$(aws --version 2>&1) || { printf 'Could not determine AWS CLI version.\n' >&2; exit 127; }
  [[ $aws_version == aws-cli/2* ]] || { printf 'AWS CLI v2 is required; found: %s\n' "$aws_version" >&2; exit 127; }
fi
for dependency in jq date; do
  command -v "$dependency" >/dev/null 2>&1 || { printf 'Required dependency is missing: %s\n' "$dependency" >&2; exit 127; }
done

case $ACTION in
  backup) run_backup ;;
  retention) run_retention ;;
  all) run_backup; run_retention ;;
esac
write_reports
if ((${#ERRORS[@]} > 0)); then exit 1; fi
