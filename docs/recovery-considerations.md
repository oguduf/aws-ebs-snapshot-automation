# Recovery considerations

EBS snapshots are incremental after the first snapshot for a volume. A snapshot is a point-in-time block-level backup, but an individual snapshot does not guarantee application consistency. Databases may need quiescing, log coordination, or native backup tooling. Multi-volume applications need coordinated snapshots or an application-aware backup design.

Before enabling cleanup, test restore procedures and recovery time, maintain the required number of recovery points, verify encryption/KMS access, inspect AMI dependencies and Recycle Bin rules, and confirm business/legal retention. AWS Backup and Amazon Data Lifecycle Manager may be better managed services for schedules, lifecycle, governance, and auditability.
