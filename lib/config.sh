#!/usr/bin/env bash

# Parse only known scalar assignments and quoted AWS_REGIONS arrays. Never eval/source.
load_config_file() {
  local file=$1 line key value regions_raw
  [[ -r $file ]] || { printf 'Configuration file is not readable: %s\n' "$file" >&2; return 2; }
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%%#*}
    [[ $line =~ ^[[:space:]]*([A-Z_]+)[[:space:]]*=(.*)$ ]] || continue
    key=${BASH_REMATCH[1]}; value=${BASH_REMATCH[2]}
    value=${value#"${value%%[![:space:]]*}"}; value=${value%"${value##*[![:space:]]}"}
    if [[ $key == AWS_REGIONS ]]; then
      regions_raw=${value#\(}; regions_raw=${regions_raw%\)}
      mapfile -t AWS_REGIONS < <(grep -oE '"[a-z0-9-]+"' <<<"$regions_raw" | tr -d '"')
      continue
    fi
    value=${value#\"}; value=${value%\"}; value=${value#\'}; value=${value%\'}
    case $key in
      BACKUP_TAG_KEY) BACKUP_TAG_KEY=$value ;;
      BACKUP_TAG_VALUE) BACKUP_TAG_VALUE=$value ;;
      RETENTION_DAYS) RETENTION_DAYS=$value ;;
      MIN_RECOVERY_POINTS) MIN_RECOVERY_POINTS=$value ;;
      BACKUP_INTERVAL_HOURS) BACKUP_INTERVAL_HOURS=$value ;;
      MANAGED_BY_TAG) MANAGED_BY_TAG=$value ;;
      BACKUP_POLICY_TAG) BACKUP_POLICY_TAG=$value ;;
      EXECUTION_MODE) EXECUTION_MODE=$value ;;
      DRY_RUN) DRY_RUN=$value ;;
      ALLOW_SNAPSHOT_CREATION) ALLOW_SNAPSHOT_CREATION=$value ;;
      ALLOW_SNAPSHOT_DELETION) ALLOW_SNAPSHOT_DELETION=$value ;;
      REPORT_DIRECTORY) REPORT_DIRECTORY=$value ;;
      LOG_LEVEL) LOG_LEVEL=$value ;;
      ENVIRONMENT) ENVIRONMENT=$value ;;
      REFERENCE_TIME) REFERENCE_TIME=$value ;;
      *) printf 'Ignoring unsupported configuration key: %s\n' "$key" >&2 ;;
    esac
  done < "$file"
}

parse_arguments() {
  local config_file="" arg
  for arg in "$@"; do
    if [[ $arg == --config ]]; then config_file=__next__; continue; fi
    if [[ $config_file == __next__ ]]; then config_file=$arg; break; fi
  done
  [[ -z $config_file || $config_file == __next__ ]] || load_config_file "$config_file"

  while (($#)); do
    case $1 in
      --help|-h) print_help; exit 0 ;;
      --config) shift 2 ;;
      --mode) EXECUTION_MODE=${2:?missing value}; shift 2 ;;
      --action) ACTION=${2:?missing value}; shift 2 ;;
      --fixtures) FIXTURE_DIR=${2:?missing value}; shift 2 ;;
      --regions) IFS=',' read -r -a AWS_REGIONS <<<"${2:?missing value}"; shift 2 ;;
      --retention-days) RETENTION_DAYS=${2:?missing value}; shift 2 ;;
      --backup-interval-hours) BACKUP_INTERVAL_HOURS=${2:?missing value}; shift 2 ;;
      --reference-time) REFERENCE_TIME=${2:?missing value}; shift 2 ;;
      --output) OUTPUT=${2:?missing value}; shift 2 ;;
      --format) OUTPUT_FORMAT=${2:?missing value}; shift 2 ;;
      --dry-run) DRY_RUN=true; shift ;;
      --execute) EXECUTE=true; DRY_RUN=false; shift ;;
      --allow-snapshot-creation) ALLOW_SNAPSHOT_CREATION=true; shift ;;
      --allow-snapshot-deletion) ALLOW_SNAPSHOT_DELETION=true; shift ;;
      --confirm-deletion) CONFIRM_DELETION=${2:?missing value}; shift 2 ;;
      *) printf 'Unknown option: %s\n' "$1" >&2; return 2 ;;
    esac
  done
}

print_help() {
  cat <<'HELP'
Usage: ebs-backup.sh [OPTIONS]
Default: offline fixture simulation; never contacts AWS.

Options:
  --mode offline|live-discovery|live-snapshot|live-cleanup
  --action backup|retention|all
  --config FILE                 Read a restricted, trusted .conf file (no eval)
  --fixtures DIR                Synthetic fixture directory (offline mode)
  --regions r1,r2               Regions to evaluate
  --retention-days N            Retention period (default 30)
  --backup-interval-hours N     Duplicate prevention interval (default 24)
  --reference-time ISO8601      Deterministic UTC reference time for tests
  --format json                 Report format (only json is supported)
  --output FILE                 Report output path
  --execute                     Disable application dry-run for gated live actions
  --allow-snapshot-creation     Required with live-snapshot and --execute
  --allow-snapshot-deletion     Required with live-cleanup and --execute
  --confirm-deletion TOKEN      Must equal DELETE-MANAGED-EBS-SNAPSHOTS
  --dry-run                     Force no resource mutations
  --help                        Show this help

Live cleanup additionally requires AWS_EBS_CLEANUP_APPROVED=true in the environment.
HELP
}
