# Installed as /etc/profile.d/ehpc.sh on every node. Login shells (including
# Claude Science's SSH probe, which looks for $SCRATCH) see the shared paths.
export SCRATCH="/shared/scratch/$USER"
export EHPC_ENV=/shared/envs/esm
export EHPC_WORKLOADS=/shared/opt/ehpc/workloads
export TORCH_HOME=/shared/cache/torch
[ -d "$SCRATCH" ] || mkdir -p "$SCRATCH" 2>/dev/null || true
