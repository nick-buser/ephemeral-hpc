# Work log

Times are US Eastern. Commit history has the detail; this records the
reasoning that does not fit in a commit message.

## 2026-10-15

- **Scoping.** The new AWS account (us-east-2, "new experience" sign-up)
  starts with a GPU quota of 0. Its AWS-managed service control policies
  deny IAM identity providers, spot instances and EC2 Fleet. Those three
  facts set the plan: CPU first ([ADR 0005](adr/0005-cpu-first.md)), no
  OIDC in CI ([ADR 0002](adr/0002-no-long-lived-credentials.md)), and
  Slurm on plain EC2 before EKS ([ADR 0001](adr/0001-slurm-on-ec2-first.md)).
- **18:42 Bootstrap stack and operator scripts.** Terraform runs on a
  homelab host because the laptop is short on disk, using `aws login`
  sessions.
- **18:50 Cluster stack.** Read the Ubuntu 24.04 `slurmd`, `slurmctld` and
  `slurmdbd` packages' systemd units before writing the boot scripts.
  `slurmd` reads `/etc/default/slurmd`, which makes configless mode a
  one-line setting. The daemons run as `slurm` with fixed runtime
  directories, which set the PID file paths. Caught before first boot: shell
  tracing would have written the munge key and database password into a
  log the `ubuntu` user can read.
- **18:50 Workload.** Sharding balances residues, not sequence counts:
  transformer cost grows with length, and the slowest node sets the wall
  time.
- **18:52 CI.** `terraform test` with a mocked AWS provider checks the
  guardrails without credentials. Trivy flagged two intended trade-offs,
  the AWS-managed S3 key and open egress. Both are annotated where they
  live.
