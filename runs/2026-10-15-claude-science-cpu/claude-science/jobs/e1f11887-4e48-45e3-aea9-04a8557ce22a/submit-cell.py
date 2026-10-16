emb = '/shared/scratch/ubuntu/.claude-science/jobs/d69aead0-152c-4ee2-be8d-803fb4e4c558/out_n3'
script = f'''#SBATCH --nodes=3
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=2
#SBATCH --time=00:30:00
#SBATCH --partition=cpu
source /etc/profile.d/ehpc.sh
export SRUN_CPUS_PER_TASK=$SLURM_CPUS_PER_TASK
ls -l {emb}/shard-*.npz
srun "$EHPC_ENV/bin/python" "$EHPC_WORKLOADS/protein/train_probe.py" --embeddings {emb} --out out 2>&1 | tee train.log
ls -lh out || true'''
job2 = c.submit_job(
    intent='DDP (gloo) enzyme classifier on 3 nodes from the 3-node ESM-2 8M embeddings of job d69aead0 — 30 epochs, ~minutes',
    command=script,
    outputs=['out/metrics.json', 'train.log'],
    run_timeout_s=1800,
)
print(job2.id, job2.state())
