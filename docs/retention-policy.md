# Retention behavior

Retention defaults to 30 days. The UTC reference time is `--reference-time` when provided, otherwise the current UTC time. A snapshot is expired only when `StartTime < reference_time - retention_days`; at the exact threshold it remains within retention.

Only snapshots with the exact `ManagedBy` tag and a nonempty owner are considered. Deletion candidates must be completed, have a valid source-volume tag and timestamp, be expired, not carry a protection/hold tag, leave at least `MIN_RECOVERY_POINTS` completed managed snapshots for that source volume, not be referenced by an AMI, and not match an active applicable EBS snapshot Recycle Bin rule. Failed AMI or Recycle Bin checks block eligibility.

An expired snapshot may be listed in `expired_snapshots` while also appearing in `protected_snapshots`; this makes the age decision visible while preserving why cleanup is blocked. `deletion_candidates` are proposals only unless all live cleanup gates pass. Recycle Bin rules that match a snapshot are treated conservatively as operator-review protection.

Retention is not an RPO guarantee. Deleting a snapshot does not necessarily remove all underlying blocks if later snapshots reference them. Keep enough recoverable points to satisfy recovery, legal, compliance, and business requirements. Concurrent runs can race between inventory and deletion; use orchestration locking and repeat preflight checks in production.
