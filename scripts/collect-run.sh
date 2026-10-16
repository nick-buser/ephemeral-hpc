#!/usr/bin/env bash
# Copy a run's record off the cluster before it terminates. Everything on the
# cluster, /shared and the accounting database included, is gone after
# teardown, so run this first.
#
#   scripts/collect-run.sh 2026-10-15-claude-science
#
# Writes runs/<name>/:
#   slurm/    sacct for every job and step, cluster config, node shapes
#   jobs/     the scratch tree: job scripts, logs, timings, metrics
#             (embeddings, checkpoints, datasets and images stay behind)
#   nodes/    per-node boot log, Slurm daemon logs, boot timing
#   aws/      instances and the run window's CloudWatch metrics
#
# The account ID, the operator's public IP and every node's public IP are
# replaced with placeholders, then the tree is scanned for key material.
# Review the diff before committing anyway.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
[[ -f "$repo_root/.operator.env" ]] && source "$repo_root/.operator.env"

name="${1:?usage: collect-run.sh <run-name>}"
alias_name="${EHPC_SSH_ALIAS:-ehpc-admin}" # needs sudo for daemon logs
profile="${AWS_PROFILE:-ephemeral-hpc}"
region="${AWS_REGION:-us-east-2}"
out="$repo_root/runs/$name"
mkdir -p "$out"/{slurm,jobs,nodes,aws}

ssh_opts=(-n -o BatchMode=yes -o ConnectTimeout=15) # -n: never read the caller's stdin
# shellcheck disable=SC2029 # remote commands are built here on purpose
on_head() { ssh "${ssh_opts[@]}" "$alias_name" "$@"; }
# Compute nodes have no public SSH; reach them through the head.
on_node() {
  local addr="$1"
  shift
  ssh "${ssh_opts[@]}" -o ProxyJump="$alias_name" -o IdentitiesOnly=yes \
    -i "${EHPC_SSH_KEY:-$HOME/.ssh/ehpc_ed25519}" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$HOME/.ssh/known_hosts.$alias_name" \
    "ubuntu@$addr" "$@"
}
# Run the AWS CLI where the `aws login` session lives.
aws_cli() {
  if [[ -n "${OPERATOR_HOST:-}" ]]; then
    # shellcheck disable=SC2029 # quoted with %q for the remote shell
    ssh "${ssh_opts[@]}" "$OPERATOR_HOST" "$(printf '%q ' aws --profile "$profile" --region "$region" "$@")"
  else
    aws --profile "$profile" --region "$region" "$@"
  fi
}

# 1. Slurm accounting. The database is per cluster, so "since 2000" is all of it.
fields=JobID,JobName,User,Partition,NNodes,NCPUS,NTasks,NodeList,State,ExitCode
fields+=,Submit,Start,End,Elapsed,TotalCPU,CPUTime,MaxRSS,MaxRSSNode,AveRSS
fields+=,MaxDiskRead,MaxDiskWrite,AllocTRES,TRESUsageInTot,WorkDir,SubmitLine
on_head "sacct -a -P -S 2000-01-01 -o $fields" >"$out/slurm/sacct.psv"
on_head "sacct -a --json -S 2000-01-01" >"$out/slurm/sacct.json" 2>/dev/null ||
  rm -f "$out/slurm/sacct.json" # needs the JSON serializer plugin
on_head 'scontrol show config; echo; scontrol show nodes; echo; sinfo -N -l' \
  >"$out/slurm/cluster.txt"

# 2. From the scratch tree, which the agent can write to, only regular
#    files of known text types under 1 MiB (`-size -1M` would round up and
#    match only empty files): no symlinks, no binaries, no
#    datasets, nothing planted under another name.
on_head 'cd /shared/scratch && find . -type f -size -1024k \( -name "*.log" -o -name "*.out" -o -name "*.err" -o -name "*.json" -o -name "*.csv" -o -name "*.txt" -o -name "*.sh" -o -name "*.py" -o -name "*.sbatch" -o -name "*.def" \) -print0 | tar --null -T - -czf -' |
  tar -C "$out/jobs" -xzf -

# 3. Per-node logs and boot timing.
collect_node() { # name, runner...
  local node="$1"
  shift
  mkdir -p "$out/nodes/$node"
  "$@" 'sudo cat /var/log/ehpc-init.log' >"$out/nodes/$node/ehpc-init.log" || true
  "$@" 'sudo sh -c "cat /var/log/slurm/*.log"' >"$out/nodes/$node/slurm.log" || true
  "$@" 'systemd-analyze; cloud-init analyze show 2>/dev/null | tail -40' \
    >"$out/nodes/$node/boot-timing.txt" || true
}
collect_node head on_head
while read -r node addr; do
  collect_node "$node" on_node "$addr"
done < <(on_head "sinfo -h -N -o '%N %o'" | sort -u)

# 4. AWS: instances and CloudWatch for the run window. Basic monitoring is
#    5-minute resolution; the dashboard reads the same series.
# shellcheck disable=SC2016 # backticks are JMESPath literals
aws_cli ec2 describe-instances \
  --filters Name=tag:Project,Values=ephemeral-hpc Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].{id:InstanceId,name:Tags[?Key==`Name`]|[0].Value,type:InstanceType,az:Placement.AvailabilityZone,launched:LaunchTime}' \
  --output json >"$out/aws/instances.json"
start=$(python3 -c 'import json,sys; print(min(i["launched"] for i in json.load(open(sys.argv[1]))))' "$out/aws/instances.json")
end=$(date -u +%Y-%m-%dT%H:%M:%SZ)
queries=$(python3 - "$out/aws/instances.json" <<'PY'
import json, sys
qs = []
for n, inst in enumerate(json.load(open(sys.argv[1]))):
    for m, metric in enumerate(["CPUUtilization", "NetworkIn", "NetworkOut"]):
        qs.append({
            "Id": f"m{n}_{m}",
            "Label": f'{inst["name"]} {metric}',
            "MetricStat": {
                "Metric": {"Namespace": "AWS/EC2", "MetricName": metric,
                           "Dimensions": [{"Name": "InstanceId", "Value": inst["id"]}]},
                "Period": 60 if metric == "CPUUtilization" else 300,
                "Stat": "Maximum" if metric == "CPUUtilization" else "Sum",
            },
        })
print(json.dumps(qs))
PY
)
aws_cli cloudwatch get-metric-data --start-time "$start" --end-time "$end" \
  --metric-data-queries "$queries" --output json >"$out/aws/cloudwatch-ec2.json"

# 5. Scrub, then refuse to leave anything that looks like a secret.
account=$(aws_cli sts get-caller-identity --query Account --output text)
operator_ip=$(curl -fsS https://checkip.amazonaws.com)
# Every node's public IP, not just the head's: compute nodes have them too.
# shellcheck disable=SC2207 # whitespace-separated IPs
node_ips=($(aws_cli ec2 describe-instances \
  --filters Name=tag:Project,Values=ephemeral-hpc Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].PublicIpAddress' --output text))
patterns=(-e "$account" -e 'X-aws-ec2-metadata-token: [A-Za-z0-9]' -e '^\++ *token=[A-Za-z0-9]' -e "${operator_ip//./\\.}")
subs=(-e "s/${account}/<account-id>/g"
  -e 's/\(X-aws-ec2-metadata-token: \)[A-Za-z0-9_=-]*/\1<redacted>/g'
  -e 's/^\(+* *token=\)[A-Za-z0-9_=-]*/\1<redacted>/'
  -e "s/${operator_ip//./\\.}/<operator-ip>/g")
for ip in "${node_ips[@]}"; do
  patterns+=(-e "${ip//./\\.}")
  subs+=(-e "s/${ip//./\\.}/<node-public-ip>/g")
done
{ grep -rIlE "${patterns[@]}" "$out" || true; } | while read -r f; do
  sed -i.bak "${subs[@]}" "$f"
  rm -f "$f.bak"
done
# Key IDs need boundaries: protein sequences are long runs of capitals and
# contain "ASIA" followed by 16 more of them.
if grep -rIlE 'BEGIN [A-Z ]*PRIVATE KEY|StoragePass|aws_secret_access_key|(^|[^A-Z0-9])(AKIA|ASIA)[A-Z0-9]{16}([^A-Z0-9]|$)|metadata-token: [A-Za-z0-9]|^\++ *token=[A-Za-z0-9]' "$out"; then
  echo "refusing: the files above look like they hold secrets" >&2
  exit 1
fi

{
  echo "collected: $end"
  echo "repo: $(git -C "$repo_root" rev-parse --short HEAD)"
  (cd "$out" && find . -type f | sort | xargs du -k)
} >"$out/MANIFEST.txt"
echo "wrote $out ($(du -sh "$out" | cut -f1))"
