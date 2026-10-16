# 0007 Jobs run inside an Apptainer image

**Status:** accepted, 2026-10-16

## Context

Until now the workload's Python environment was a venv on `/shared`, built
at boot, plus a model-weight cache next to it. Two problems:

- **Legibility.** A scientist reading the repo expects the runtime to be a
  container image they can pull, inspect and rerun elsewhere. A venv on an
  NFS share is an implementation detail of one cluster.
- **Isolation.** [ADR 0006](0006-agent-sandbox.md) confines the agent with
  host controls: an unprivileged user, UID-matched egress rules, a proxy.
  Jobs still saw the whole host filesystem and process table.

Apptainer (formerly Singularity) is the container runtime HPC sites
standardise on. Unlike Docker it needs no daemon, runs containers as the
calling user, and works with Slurm, MPI and shared filesystems without
special integration.

## Decision

1. **Apptainer 1.5.4, non-setuid build**, installed on every node from the
   project's GitHub release, pinned by version and SHA-256. Containers run
   in unprivileged user namespaces. Ubuntu 24.04 blocks those by default
   (`kernel.apparmor_restrict_unprivileged_userns=1`); the package installs
   an AppArmor profile that allows them for Apptainer only, so the sysctl
   stays on for everything else.
2. **One image, `esm.sif`, built from [`workloads/container/esm.def`](../../workloads/container/esm.def)**:
   `python:3.12-slim` pinned by digest, the pinned requirements, and the
   ESM-2 weights baked in, so a job needs no network to load a model. The
   head node builds it at boot as root (393 s on a t3.small, 427 MB) into
   `/shared/containers/`, root-owned and read-only to everyone else.
3. **`$EHPC_PY` is the only Python for jobs.** It runs
   `apptainer exec --contain --ipc --pid --bind /shared` on the image:
   empty private `$HOME` and `/tmp`, host `/etc` out of view, own IPC and
   PID namespaces, `/shared` at the same path. The environment passes
   through, so ranks read `SLURM_*` and pip reads the proxy settings.
4. **The host controls stay.** The container process keeps the agent's
   UID, so the nftables rules and the proxy allowlist apply inside it
   unchanged. The container adds filesystem and process isolation; the
   host still owns network and identity.
5. **The agent cannot map other UIDs.** The package depends on `uidmap`,
   whose setuid `newuidmap` lets a user with a subordinate UID range run
   container processes as other host UIDs, outside rule 4. Boot creates
   users with no subordinate ranges, drops the setuid bit from
   `newuidmap` and `newgidmap`, and the egress rules also match UIDs
   100000 and up (added 2026-10-16 after review;
   [notes, finding 17](../notes/agent-isolation.md)).

## Consequences

- Measured on one node, same 300 proteins: 1,795.6 residues/s inside the
  container, 1,773.2 on the host. Startup is 0.21 s, because the image is
  mounted with squashfuse rather than unpacked.
- Boot takes about 7 minutes longer, for the image build. Building once in
  CI, signing it and pulling it by digest would remove that and give a
  verifiable artifact; that needs a public registry or one the nodes can
  authenticate to.
- `scontrol` is not in the image, so the trainer finds its rendezvous host
  by parsing `SLURM_STEP_NODELIST` itself (`shard.first_host`).
- Nothing forces a job into the container. The agent could still run host
  `python3` (standard library only) under the same host controls. Slurm's
  OCI container support or a job-submit plugin could enforce it.
- Non-setuid mode ignores `apptainer.conf` limits such as `limit container
  paths`, so the agent could run another image. It cannot pull a new base:
  no registry is on the proxy allowlist.
