#!/bin/bash
#SBATCH --job-name=esm-probe-ddp
#SBATCH --nodes=3
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=2
#SBATCH --time=00:30:00
#SBATCH --output=%x-%j.log
# Multi-node DDP over the embeddings written by embed.sbatch.
set -euo pipefail
# shellcheck source=/dev/null # installed by cloud-init from infra/templates/ehpc-profile.sh
source /etc/profile.d/ehpc.sh
export SRUN_CPUS_PER_TASK="$SLURM_CPUS_PER_TASK" # srun does not inherit it from sbatch
srun "$EHPC_ENV/bin/python" "$EHPC_WORKLOADS/protein/train_probe.py" \
  --embeddings "${OUT:-out}" --out "${OUT:-out}" "$@"
