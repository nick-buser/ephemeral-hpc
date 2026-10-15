#!/usr/bin/env bash
# Run terraform for one stack on the operator host.
#
#   scripts/tf.sh bootstrap apply
#   scripts/tf.sh infra plan
#   scripts/tf.sh infra destroy -auto-approve
#
# Syncs this checkout to OPERATOR_HOST (or runs locally when unset), computes
# the per-operator inputs here — public IP for the SSH allowlist, SSH public
# key — and hands them to scripts/tf-run.sh, which fetches short-lived
# credentials from `aws login`. Nothing it passes is written to the repo.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
[[ -f "$repo_root/.operator.env" ]] && source "$repo_root/.operator.env"

stack="${1:?usage: tf.sh <bootstrap|infra> <terraform args...>}"
shift
case "$stack" in bootstrap | infra) ;; *)
  echo "unknown stack: $stack" >&2
  exit 2
  ;;
esac

pubkey_file="${EHPC_SSH_PUBKEY_FILE:-$HOME/.ssh/ehpc_ed25519.pub}"
env_args=(
  "AWS_PROFILE=${AWS_PROFILE:-ephemeral-hpc}"
  "AWS_REGION=${AWS_REGION:-us-east-2}"
)
if [[ "$stack" == infra ]]; then
  admin_ip="$(curl -fsS https://checkip.amazonaws.com)"
  env_args+=(
    "TF_VAR_admin_cidrs=[\"${admin_ip}/32\"]"
    "TF_VAR_ssh_public_key=$(cat "$pubkey_file")"
  )
fi
if [[ "$stack" == bootstrap ]]; then
  env_args+=("TF_VAR_alert_email=${EHPC_ALERT_EMAIL:?set EHPC_ALERT_EMAIL in .operator.env}")
fi

if [[ -z "${OPERATOR_HOST:-}" ]]; then
  exec env "${env_args[@]}" "$repo_root/scripts/tf-run.sh" "$stack" "$@"
fi

remote_dir="${OPERATOR_DIR:-ephemeral-hpc}"
rsync -a --delete \
  --exclude .git/ --exclude .operator.env \
  --exclude .terraform/ --exclude '*.tfstate*' --exclude '*.tfplan' \
  "$repo_root/" "$OPERATOR_HOST:$remote_dir/"

quoted_env=$(printf '%q ' "${env_args[@]}")
quoted_args=$(printf '%q ' "$stack" "$@")
ssh -t "$OPERATOR_HOST" "cd $remote_dir && env $quoted_env scripts/tf-run.sh $quoted_args"

# Provider lock files are generated where terraform runs; keep them in git.
rsync -a "$OPERATOR_HOST:$remote_dir/$stack/.terraform.lock.hcl" "$repo_root/$stack/" 2>/dev/null || true
