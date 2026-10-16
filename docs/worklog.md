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
- **23:42 Third cluster, idle window raised to 120 minutes.** The second
  cluster went the same way as the first: Claude Science's resubmission
  waited on its approval card, and the alarms terminated every node at
  23:16–23:27. The cluster was rebuilt once more after the change.

## 2026-10-16

- **00:01–00:56 The Claude Science run.** The embedding job (1, 2 and 3
  nodes in one allocation) ran 53 minutes and the 3-node DDP job 17
  seconds, both submitted by the agent through approval cards. Claude
  Science deletes its job directories on the cluster after copying outputs
  back, so `job.sh` survives only in its own session; the run record takes
  the submit cells from there.
- **01:13 Harvest.** `scripts/collect-run.sh` saved accounting, logs and
  metrics; the job scripts and per-node timings came from Claude Science's
  workspace. Nothing in the record holds the account ID or a public IP.
- **01:20 The accounting found a scheduler bug.** `sacct` showed each
  embedding step using half its allocated CPU time. A task given 2 CPUs saw
  one (`Cpus_allowed_list: 0`, even with `--cpu-bind=none`), because
  `slurm.conf` described the nodes only as `CPUs=2` while the hardware is
  1 core × 2 threads. Declaring the topology on the live cluster gave the
  task both threads and lifted one-node throughput on a fixed 300-protein
  sample from 1,467 to 1,773 residues/s. The fix is in Terraform with a
  test. The scaling table stands as measured, at one vCPU per node.
- **01:45 Was the cluster sandboxed? No.** The network kept the internet
  out, but the agent ran as `ubuntu` with passwordless sudo: IMDS
  credentials, open egress, and a TTL it could cancel. Built the agent
  user, UID-matched nftables egress, a squid allowlist, an EventBridge TTL
  outside the instances, and dropped the SSM managed policy
  ([ADR 0006](adr/0006-agent-sandbox.md)).
- **02:00 First live sandbox check.** It reported all PASS, which was
  itself a bug: `srun` swallowed the rest of the script and the compute
  nodes were never checked. Reading the evidence it printed turned up
  three more: a check passing through the wrong layer, an nft rule that
  rejected kernel packets, and squid trusting reverse DNS. All four fixed
  and rechecked live: 31 PASS.
- **02:10 Apptainer.** Prototyped by hand on the live cluster before any
  Terraform: the container keeps the agent's UID, so the host firewall
  applies inside it; no measurable overhead. Then into IaC, where the
  user-data size test and a compute-replacement gap each caught a real
  problem before EC2 did ([ADR 0007](adr/0007-apptainer.md)). The
  reasoning and the findings are collected in
  [notes/agent-isolation.md](notes/agent-isolation.md).
