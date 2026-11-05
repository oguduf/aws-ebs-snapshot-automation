# Limitations

- No AWS authentication or live AWS API call was made for this lab.
- No EC2 instance was changed and no EBS snapshot was created or deleted.
- Offline fixtures are synthetic and cannot validate real account permissions or API behavior.
- AMI references are checked, but snapshots may have other recovery, compliance, or organizational dependencies.
- Recycle Bin matching covers configured EBS snapshot rule tags; broader governance remains an operator preflight.
- The CLI does not provide distributed locking; concurrent invocations can still race.
- An EBS snapshot does not automatically produce an application-consistent or multi-volume recovery point.
