#!/bin/bash
#SBATCH --job-name=esm-embed
#SBATCH --nodes=3
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=2
#SBATCH --time=00:30:00
#SBATCH --output=%x-%j.log
# Fetch the dataset once, then embed it with one task per node.
# Override the node count at submit time: sbatch --nodes=1 embed.sbatch
set -euo pipefail
source /etc/profile.d/ehpc.sh
export SRUN_CPUS_PER_TASK="$SLURM_CPUS_PER_TASK" # srun does not inherit it from sbatch
py="$EHPC_ENV/bin/python"
here="$EHPC_WORKLOADS/protein"

srun --nodes=1 --ntasks=1 "$py" "$here/fetch_uniprot.py"
srun "$py" "$here/embed.py" --out "${OUT:-out}" "$@"
ls -lh "${OUT:-out}" || true
