# Driving the cluster from Claude Science

[Claude Science](https://claude.com/docs/claude-science/remote-compute-clusters)
connects to SSH hosts listed in `~/.ssh/config`. On a host where `sbatch`
exists, it submits jobs to Slurm, polls them, and copies outputs back into
the session. `scripts/ssh-config.sh` adds this cluster as `Host ehpc`, which
logs in as `agent`: an unprivileged user with no sudo, no AWS credentials and
no internet except an allowlist ([ADR 0006](adr/0006-agent-sandbox.md)).

## Add the host

1. **Settings › Compute › SSH hosts › Add SSH host**, alias `ehpc`.
2. Paste the notes below into the host's notes.
3. On the host's detail page, set **Scratch directory** to
   `/shared/scratch/agent`. Slurm jobs need it on the shared filesystem.

```
Slurm cluster built by github.com/nick-buser/ephemeral-hpc.
Partition: cpu (default), nodes compute-[1-3], 2 CPUs and ~6.8 GB each.
/shared is NFS from the head node and visible on every node.
You are the unprivileged user "agent": no sudo, and the only internet
  access is an allowlisting proxy (UniProt, PyPI, PyTorch, ESM weights)
  that /etc/profile.d/ehpc.sh configures. Other hosts are refused.
Python runs inside an Apptainer image: source /etc/profile.d/ehpc.sh,
  then use $EHPC_PY in place of python (in srun lines too). The image
  ($EHPC_SIF) holds torch 2.8 CPU, fair-esm 2.0, numpy, scikit-learn and
  the ESM-2 weights. It is read-only; /shared is mounted inside it.
Pipeline code: $EHPC_WORKLOADS/protein (fetch_uniprot.py, embed.py,
  train_probe.py). Run each multi-node step with srun, one task per node:
  #SBATCH --nodes=3 --ntasks-per-node=1 --cpus-per-task=2
  export SRUN_CPUS_PER_TASK=$SLURM_CPUS_PER_TASK
Dataset: /shared/data/uniprot_human.tsv, fetched at boot (6,000 proteins).
The cluster terminates itself after 4 hours or 120 idle minutes. If an
  SSH connection times out, the cluster may have been rebuilt; ask the
  operator rather than retrying.
```

## The prompt

> Using the ehpc cluster, embed the UniProt sample with ESM-2 8M on 1, 2 and
> 3 nodes and compare throughput. Then train the enzyme classifier with DDP
> on 3 nodes from the 3-node embeddings and report held-out accuracy and
> AUROC against the majority-class baseline.

Each submission raises an approval card that shows the job script. The
session's transcript, job scripts and outputs are the record of the run, and
the curated results go in the README.
