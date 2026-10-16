# Installed as /etc/profile.d/ehpc.sh on every node. Login shells (including
# Claude Science's SSH probe, which looks for $SCRATCH) see the shared paths.
export SCRATCH="/shared/scratch/$USER"
export EHPC_ENV=/shared/envs/esm
export EHPC_WORKLOADS=/shared/opt/ehpc/workloads
export TORCH_HOME=/shared/cache/torch
[ -d "$SCRATCH" ] || mkdir -p "$SCRATCH" 2>/dev/null || true

# The agent user has no direct route out (agent-egress.nft); the domains it
# may reach go through the head node's allowlisting proxy.
if [ "$(id -un)" = agent ]; then
  export http_proxy=http://head:3128 https_proxy=http://head:3128
  export HTTP_PROXY=$http_proxy HTTPS_PROXY=$https_proxy
  export no_proxy=localhost,127.0.0.1,head NO_PROXY=localhost,127.0.0.1,head
fi
