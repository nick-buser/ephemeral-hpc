# 0005 CPU first: the account's GPU quota starts at zero

**Status:** accepted, 2026-10-15

## Context

New AWS accounts start with a quota of 0 vCPUs for "Running On-Demand G and
VT instances" (L-DB2E81BA). Three `g4dn.xlarge` nodes need 12. Increases
can take a day or more, and new accounts are sometimes refused. This
account's managed policies also deny spot instances and EC2 Fleet.

## Decision

Ship the cluster on free-tier-eligible CPU types today: `t3.small` for the
head node and `m7i-flex.large` for compute. The workload chooses its backend
at runtime: CUDA and NCCL when a GPU is present, CPU and gloo otherwise. The
ESM-2 models it uses (8M and 35M parameters) are small enough to embed a
6,000-protein sample on CPU in minutes.

## Consequences

- The first results measure CPU scaling. Absolute throughput says nothing
  about GPU performance and is reported that way.
- GPU nodes are a variable change plus an NVIDIA driver AMI and GRES
  configuration. That path is untested until the quota is granted, and the
  README says so.
