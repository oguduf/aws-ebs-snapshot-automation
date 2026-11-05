# Security model

## Execution controls

- Offline fixture mode is the default and never calls the `aws` executable.
- Live discovery requires explicit mode selection and stays read-only.
- Snapshot creation requires `--mode live-snapshot --execute --allow-snapshot-creation`.
- Cleanup requires `--mode live-cleanup --execute --allow-snapshot-deletion --confirm-deletion DELETE-MANAGED-EBS-SNAPSHOTS` and `AWS_EBS_CLEANUP_APPROVED=true`.
- Configuration is parsed as a small allowlisted assignment format; it is never `source`d or evaluated. Treat config as trusted input regardless.
- AWS credentials come from the caller's approved role/profile/credential chain. The script never reads, prints, or stores credentials.
- Snapshot deletion is not retried by this script; `AWS_MAX_ATTEMPTS=1` is set for the delete call.
- Read-only discovery uses standard AWS CLI retries; non-idempotent snapshot creation and deletion use one attempt to avoid blind mutation retries.

The cleanup approval environment variable is an operator assertion that change approval, minimum recovery-point requirements, compliance holds, legal restrictions, Recycle Bin applicability, and organization policy have been reviewed. The script does not establish all those governance facts. Use a single-writer scheduler/lock in production to prevent concurrency races.

## IAM

`iam/least-privilege-policy.example.json` separates broad-resource discovery calls from narrower create/tag/delete actions. EC2 Describe APIs do not all support resource-level authorization and therefore use `Resource: "*"`; this is called out in the policy. The example uses the synthetic account ID `111122223333`, which must be replaced with the authorized account ID after review.

Use temporary credentials from an IAM role with the smallest required region and resource scope. Prefer separate read-only discovery and snapshot mutation roles. Do not attach the example blindly: validate EC2 action/resource support and tag condition keys against the actual account and organizational guardrails.

CloudTrail can audit EC2 snapshot operations in an authorized production account. This repository does not create IAM roles, CloudTrail, schedules, or infrastructure.
