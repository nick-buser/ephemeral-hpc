# 0001 Slurm on plain EC2 before Slinky on EKS

**Status:** accepted, 2026-10-15

## Context

The goal is a multi-node cluster that Claude Science can drive. Claude
Science submits to Slurm when it finds `sbatch` on an SSH host. Two ways to
give it one:

1. Slurm installed directly on EC2 instances by cloud-init.
2. Slinky (SchedMD's slurm-operator) on EKS, where Slurm daemons run as pods.

AWS's managed Slurm (Parallel Computing Service) is not available on this
account type. Option 2 also needs an EKS control plane ($0.10/hour), a
system node group, cert-manager, a shared ReadWriteMany volume (EFS), and a
way to expose the login pod over SSH. EKS create and destroy cycles take
15–20 minutes each.

## Decision

Build option 1 first. It has fewer moving parts and boots in minutes, which
keeps debugging cheap. It also exercises the parts that carry over to
Slinky: Slurm configuration, job accounting, shared storage, munge key
distribution and the Claude Science integration.

## Consequences

- Nodes are pets for their short life. A failed node is fixed by
  `terraform apply`, not by a controller.
- Slinky on EKS stays on the roadmap as the next stage. When it lands, the
  workload code and the Claude Science side stay the same.
