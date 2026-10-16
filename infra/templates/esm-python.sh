#!/bin/sh
# Installed as /shared/opt/ehpc/bin/esm-python ($EHPC_PY). Runs Python inside
# the cluster's Apptainer image (docs/adr/0007-apptainer.md).
#   --contain   empty private $HOME and /tmp; host /etc stays out
#   --ipc --pid private IPC and PID namespaces
#   --bind /shared  datasets, scratch and results at the same paths
# The environment passes through (no --cleanenv): ranks read SLURM_* and
# pip reads the proxy settings. The process keeps the caller's UID, so the
# host's agent egress rules still apply inside.
exec apptainer exec --contain --ipc --pid --bind /shared --pwd "$PWD" \
  /shared/containers/esm.sif python "$@"
