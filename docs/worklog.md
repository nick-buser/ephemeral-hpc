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
- **20:41 Spending limits.** `aws freetier get-account-plan-state` shows
  the Free plan with $100 of credit. That plan is the hard cap: AWS cannot
  charge the card. Spend limits need the Paid plan and have no API.
- **21:00 First deploy.** Bootstrap applied in about a minute. The cluster
  stack (33 resources) applied in 42 seconds at 21:01. The head node
  finished cloud-init, Slurm accounting, the Python environment and the
  ESM-2 weights at 21:07. All three compute nodes joined `idle` on first
  boot.
- **21:03 Fix: `ssh-config.sh` had no credentials.** It ran `terraform
  output` without the `aws login` exchange, and the S3 backend refused.
- **21:08 Smoke run, 300 proteins.** Embedding on three nodes took 45 s,
  about 1,300 residues/s per node on 2 vCPUs. Training wrote its metrics,
  but one rank aborted at shutdown and Slurm marked the job FAILED, which
  would have broken any `afterok` chain. Rank 0 hosts the rendezvous store
  and exited while the others were tearing down. A barrier before
  `destroy_process_group()` fixed it, and the rerun exited 0 on all ranks.
  The live cluster got the fix by hand on `/shared`, so its user data no
  longer matches the repo. The next `infra apply` replaces every node.
- **22:06 The idle guardrail ended the first cluster before the real run.**
  The smoke test finished at 21:10. Claude Science connected at 21:52, then
  spent several minutes reading the host notes and pipeline code before it
  submitted. The 60-minute idle alarms terminated the head and two compute
  nodes at 22:06, so the submission had no cluster to land on. compute-1
  survived because its alarm had not fired yet. The alarms worked as designed. The lesson is about
  sequencing: the idle clock starts at the last job, so the agent session
  should start right after the cluster is ready, not after a smoke test and
  a break.
- **22:18 Rebuild.** `terraform apply` recreated the three terminated nodes.
  compute-1 had to be replaced too (`-replace`): it held the old cluster's
  munge key and an NFS mount to a head that no longer existed. Its
  termination took 4 minutes, likely shutdown waiting on that hard NFS
  mount. New nodes launched at 22:22.
