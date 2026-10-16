# 0006 What the agent can do on the cluster

**Status:** accepted, 2026-10-16

## Context

Claude Science runs commands and job scripts it writes itself, after a
human approves each one. In the first run it logged in as `ubuntu`, the
image's default user, which has passwordless sudo. That gave every job:

- root on every node,
- the node's AWS credentials, through the instance metadata service,
- unrestricted internet egress,
- the power to cancel the in-OS TTL (`shutdown -c`). The idle alarm cannot
  catch a busy runaway job, so nothing but budget alerts would stop it.

The network kept the internet out, but nothing kept the agent in. Approval
cards help, but an approval is a person skimming a script, not a boundary.

## Decision

1. **A separate, unprivileged identity.** The `agent` user (uid 2001 on
   every node, so NFS ownership and Slurm credentials agree) has its own SSH
   key and no sudo. `Host ehpc` logs in as `agent`; the operator's sudo
   login is `Host ehpc-admin`. Terraform refuses an agent key equal to the
   operator key.
2. **Default-deny egress for that identity.** An nftables table matches
   packets by owning UID. The agent may use loopback and the VPC CIDR
   (Slurm, NFS, torch.distributed, the proxy); every other connection it
   opens is rejected and logged. Replies on connections made *to* it, such
   as its own SSH session, still flow. The rules load from cloud-init
   `bootcmd`, before the user exists, and the boot scripts refuse to finish
   without them. Other users and system services are unaffected, so package
   installs and the munge key fetch still work.
3. **No cloud credentials.** The instance metadata service sits outside
   the VPC CIDR, so rule 2 covers it. The instance roles also lost
   `AmazonSSMManagedInstanceCore`, which nothing used and which can read
   every SSM parameter in the account.
4. **An allowlisting proxy.** Squid on the head node forwards requests
   from cluster addresses to an allowlist, HTTPS only, and logs each one.
   The agent's login profile points at it. The list is UniProt only:
   packages and weights live in the image ([ADR 0007](0007-apptainer.md)),
   and shared-CDN hosts cannot be allowlisted by name alone
   ([notes, finding 18](../notes/agent-isolation.md)).
5. **Guardrails the agent cannot reach.** EventBridge Scheduler terminates
   each node 10 minutes after its in-OS TTL, through a role that can only
   terminate instances tagged for this cluster. The in-OS shutdown and the
   idle alarm remain as the first and second lines.
6. **Proof on a live cluster.** `scripts/sandbox-check.sh` logs in as the
   agent and checks each of the above, on the head and through Slurm on
   every compute node, then shows the deny log and proxy log. Its output
   goes into the run record.

## Consequences

- The agent can still use the cluster fully: submit jobs, read and write
  its scratch space and `/shared/data`, and run anything as itself.
- It cannot change the workload code, the shared Python environment, the
  firewall, Slurm's config or the cluster key.
- It can still send data out through DNS lookups (the local resolver runs
  as a system user) and to allowlisted hosts. The data here is public.
- Compute nodes keep public IPs so system services can install packages at
  boot. Taking them off the internet entirely needs a prebuilt AMI or VPC
  endpoints plus the proxy for apt; that is the next step if the workload
  ever handles data that matters.
- The operator login still has sudo and the same egress as before.
