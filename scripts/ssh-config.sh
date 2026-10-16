#!/usr/bin/env bash
# Write the cluster's ssh_config stanza (terraform output) into ~/.ssh/config
# between marker lines, replacing any earlier copy. Claude Science picks SSH
# hosts by their alias in ~/.ssh/config, so this is what makes `ehpc` show up
# under Settings > Compute > SSH hosts. Run after every apply: the head
# node's address and host key change with each cluster.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
[[ -f "$repo_root/.operator.env" ]] && source "$repo_root/.operator.env"

# State lives in S3, so reading an output needs the same short-lived
# credentials as apply; tf-run.sh fetches them. No `ssh -t` here: a TTY would
# end every line of the stanza with \r.
aws_env="AWS_PROFILE=${AWS_PROFILE:-ephemeral-hpc} AWS_REGION=${AWS_REGION:-us-east-2}"
if [[ -n "${OPERATOR_HOST:-}" ]]; then
  # shellcheck disable=SC2029 # these are meant to expand here, client side
  stanza=$(ssh "$OPERATOR_HOST" "cd ${OPERATOR_DIR:-ephemeral-hpc} && env $aws_env scripts/tf-run.sh infra output -raw ssh_config")
else
  # shellcheck disable=SC2086 # aws_env is two NAME=value words
  stanza=$(env $aws_env "$repo_root/scripts/tf-run.sh" infra output -raw ssh_config)
fi
alias_name=$(awk '/^Host /{print $2; exit}' <<<"$stanza")

config="$HOME/.ssh/config"
begin="# BEGIN ephemeral-hpc (managed by scripts/ssh-config.sh)"
end="# END ephemeral-hpc"
touch "$config"
tmp=$(mktemp)
awk -v b="$begin" -v e="$end" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$config" >"$tmp"
printf '\n%s\n%s\n%s\n' "$begin" "$stanza" "$end" >>"$tmp"
cat "$tmp" >"$config" # keep the original file's permissions and inode
rm -f "$tmp"

rm -f "$HOME/.ssh/known_hosts.${alias_name}" # new cluster, new host key
echo "wrote Host ${alias_name} to $config"
ssh -o BatchMode=yes -o ConnectTimeout=15 "$alias_name" 'hostname; sinfo -N -o "%N %T %c %m"' || true
