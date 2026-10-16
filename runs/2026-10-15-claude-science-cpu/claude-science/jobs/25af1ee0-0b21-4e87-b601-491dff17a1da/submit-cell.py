script = r'''#SBATCH --nodes=3
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=2
#SBATCH --time=01:10:00
#SBATCH --partition=cpu
source /etc/profile.d/ehpc.sh
export SRUN_CPUS_PER_TASK=$SLURM_CPUS_PER_TASK
py=$EHPC_ENV/bin/python; here=$EHPC_WORKLOADS/protein
echo "workdir $(pwd)  nodes $SLURM_JOB_NODELIST"
awk -F'\t' 'NR>1{n++; s+=$3; if($3>m)m=$3} END{print "dataset: seqs="n" residues="s" maxlen="m}' /shared/data/uniprot_human.tsv
for n in 1 2 3; do
  t0=$(date +%s.%N)
  srun --nodes=$n --ntasks=$n --ntasks-per-node=1 --cpus-per-task=2 "$py" "$here/embed.py" --model esm2_t6_8M_UR50D --out out_n$n
  t1=$(date +%s.%N)
  echo "{\"nodes\": $n, \"step_wall_seconds\": $(echo "$t1 - $t0" | bc)}" > out_n$n/step_wall.json
  cat out_n$n/step_wall.json
done
ls -lh out_n1 out_n2 out_n3 || true'''
job1 = c.submit_job(
    intent='ESM-2 8M embedding of /shared/data/uniprot_human.tsv (6,000 seqs) on 1, then 2, then 3 nodes — one 3-node allocation, ~15-30 min',
    command=script,
    outputs=['out_n*/timing-*.json', 'out_n*/step_wall.json'],
    run_timeout_s=4500,
)
print(job1)
