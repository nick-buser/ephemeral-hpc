#!/bin/bash
# Submit the two-stage workflow from the head node without an agent:
# embed, then train only if embedding succeeded (afterok dependency).
# Usage: pipeline.sh [run-dir]   (default: $SCRATCH/protein-<timestamp>)
set -euo pipefail
source /etc/profile.d/ehpc.sh
run_dir="${1:-$SCRATCH/protein-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$run_dir"
cd "$run_dir"

here="$EHPC_WORKLOADS/protein"
embed=$(sbatch --parsable "$here/embed.sbatch")
train=$(sbatch --parsable --dependency="afterok:$embed" "$here/train.sbatch")
echo "run dir: $run_dir"
echo "embed job $embed -> train job $train"
echo "watch:   squeue; sacct -j $embed,$train"
