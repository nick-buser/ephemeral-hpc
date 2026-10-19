#!/bin/bash
# Repeat the embedding scaling measurement: REPS embed.sbatch jobs at each
# node count, each with its own accounting record, packed by Slurm and never
# sharing a node. Run as the agent; summarise the harvested record with
# workloads/analysis/scaling_report.py.
# Usage: [REPS=3] [NODES="1 2 3"] scaling.sh [run-dir]
set -euo pipefail
# shellcheck source=/dev/null # installed by cloud-init from infra/templates/ehpc-profile.sh
source /etc/profile.d/ehpc.sh
run_dir="${1:-$SCRATCH/scaling-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$run_dir"
cd "$run_dir"
{
  echo "submitted $(date -u +%FT%TZ) by $(id -un)"
  cat /shared/containers/esm.sif.sha256
  sha256sum /shared/data/uniprot_human.tsv
  sinfo -N -o '%N cpus=%c sockets=%X cores=%Y threads=%Z mem=%m'
} >provenance.txt
for r in $(seq "${REPS:-3}"); do
  for n in ${NODES:-1 2 3}; do
    sbatch --parsable --nodes="$n" --exclusive --time=00:45:00 --job-name="esm-scale-n$n-r$r" \
      --export=ALL,OUT="$run_dir/n$n-r$r" "$EHPC_WORKLOADS/protein/embed.sbatch"
  done
done
echo "run dir: $run_dir"
