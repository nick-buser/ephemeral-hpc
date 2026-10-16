# ESM-2 8M embedding scaling and DDP enzyme probe on ehpc

Cluster: ehpc Slurm, partition `cpu`, nodes compute-[1-3], 2 CPUs each, CPU-only torch 2.8.
Dataset: `/shared/data/uniprot_human.tsv`, 6,000 human UniProt proteins, 2,476,635 residues.
Model: `esm2_t6_8M_UR50D`, final-layer mean-pooled embeddings, `--max-tokens 4096`, one srun task per node (2 threads).

## Embedding throughput (Slurm job d69aead0, one 3-node allocation, srun steps run back to back)

| Nodes | Slowest-rank compute (s) | srun step wall (s) | Residues/s | Sequences/s | Speedup | Parallel efficiency | Rank imbalance (max/min) |
|---|---|---|---|---|---|---|---|
| 1 | 1693.6 | 1696.2 | 1,462 | 3.54 | 1.00x | 100% | 1.000 |
| 2 | 899.6 | 902.1 | 2,753 | 6.67 | 1.88x | 94% | 1.020 |
| 3 | 599.1 | 601.0 | 4,134 | 10.01 | 2.83x | 94% | 1.036 |

Throughput is total residues divided by the slowest rank's forward-pass time. Wall-clock, which includes Python start-up and model load, gives the same speedups to within 0.01x.
Per-node rate is flat at about 1,380–1,460 residues/s. The roughly 6 % efficiency loss comes from rank imbalance (rank 1 on compute-2 was the slowest in both multi-node runs) plus per-node rate variation, not from communication, because embedding requires no inter-node traffic.

## DDP enzyme classifier (Slurm job e1f11887, 3 nodes, gloo)

MLP probe (320→128→1) trained on the 3-node embeddings for 30 epochs, batch 64 per rank, AdamW lr 1e-3. Train/test split is a fixed SHA-256 hash of the accession (20 % test).

| Metric | Probe | Majority-class baseline |
|---|---|---|
| Held-out accuracy (n=1205) | 0.9037 | 0.7560 |
| Held-out AUROC | 0.9603 | 0.5 (constant predictor) |

Train examples: 4795. Training time: 2.66 s. Final epoch loss: 0.1982. All 3 gloo ranks connected to 2 peers each.
The probe's error rate is 9.6% versus 24.4% for the baseline, a 61% relative reduction.

Caveats: this is a single run with a single seed and no confidence interval. The hash split is not homology-aware, so related proteins can fall on both sides and accuracy may be optimistic. The 3-node embedding shards (`shard-*.npz`) remain only in the job d69aead0 workdir on the ephemeral cluster.
