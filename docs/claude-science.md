# Driving the cluster from Claude Science

[Claude Science](https://claude.com/docs/claude-science/remote-compute-clusters)
connects to SSH hosts listed in `~/.ssh/config`. On a host where `sbatch`
exists, it submits jobs to Slurm, polls them, and copies outputs back into
the session. `scripts/ssh-config.sh` adds this cluster as `Host ehpc`.

## Add the host

1. **Settings › Compute › SSH hosts › Add SSH host**, alias `ehpc`.
2. Paste the notes below into the host's notes.
3. On the host's detail page, set **Scratch directory** to
   `/shared/scratch/ubuntu`. Slurm jobs need it on the shared filesystem.

```
Slurm cluster built by github.com/nick-buser/ephemeral-hpc.
Partition: cpu (default), nodes compute-[1-3], 2 CPUs and ~6.8 GB each.
/shared is NFS from the head node and visible on every node.
Python env: source /etc/profile.d/ehpc.sh, then $EHPC_ENV/bin/python
  (torch 2.8 CPU, fair-esm 2.0, numpy, scikit-learn). Do not install into it.
Pipeline code: $EHPC_WORKLOADS/protein (fetch_uniprot.py, embed.py,
  train_probe.py). Run each multi-node step with srun, one task per node:
  #SBATCH --nodes=3 --ntasks-per-node=1 --cpus-per-task=2
  export SRUN_CPUS_PER_TASK=$SLURM_CPUS_PER_TASK
Dataset: /shared/data/uniprot_human.tsv (fetch_uniprot.py creates it).
ESM-2 weights are cached in $TORCH_HOME on /shared.
The cluster terminates itself after 4 hours or 60 idle minutes.
```

## The prompt

> Using the ehpc cluster, embed the UniProt sample with ESM-2 8M on 1, 2 and
> 3 nodes and compare throughput. Then train the enzyme classifier with DDP
> on 3 nodes from the 3-node embeddings and report held-out accuracy and
> AUROC against the majority-class baseline.

Each submission raises an approval card that shows the job script. The
session's transcript, job scripts and outputs are the record of the run, and
the curated results go in the README.
