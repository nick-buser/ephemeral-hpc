#!/usr/bin/env bash
# Prove the agent sandbox holds on a live cluster. Logs in as the agent
# (Host ehpc) and checks that what it must not do fails and what it needs
# still works, on the head node and on every compute node through Slurm.
# Then, as the operator, checks the out-of-instance TTL and shows the deny
# logs. Prints PASS/FAIL per check and exits non-zero on any FAIL.
#
#   scripts/sandbox-check.sh                 # print only
#   scripts/sandbox-check.sh <run-name>      # also save runs/<run-name>/sandbox-check.txt
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
[[ -f "$repo_root/.operator.env" ]] && source "$repo_root/.operator.env"
agent_alias="${EHPC_SSH_ALIAS:-ehpc}"
admin_alias="${EHPC_ADMIN_ALIAS:-ehpc-admin}"
profile="${AWS_PROFILE:-ephemeral-hpc}"
region="${AWS_REGION:-us-east-2}"
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=15)
# Run the AWS CLI where the `aws login` session lives.
aws_cli() {
  if [[ -n "${OPERATOR_HOST:-}" ]]; then
    # shellcheck disable=SC2029 # quoted with %q for the remote shell
    ssh -n "${ssh_opts[@]}" "$OPERATOR_HOST" "$(printf '%q ' aws --profile "$profile" --region "$region" "$@")"
  else
    aws --profile "$profile" --region "$region" "$@"
  fi
}

run_checks() {
  echo "# sandbox check, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "## As the agent, on the head node and each compute node"
  # The agent-side checks run remotely; the heredoc is not expanded here.
  local agent_fails=0
  ssh "${ssh_opts[@]}" "$agent_alias" 'bash -s' <<'AGENT' || agent_fails=$?
set -u
source /etc/profile.d/ehpc.sh
fails=0
result() { if [ "$1" = 0 ]; then echo "PASS  $2"; else echo "FAIL  $2"; fails=$((fails + 1)); fi; }
denied() { local name="$1"; shift; "$@" >/dev/null 2>&1; [ $? != 0 ]; result $? "$name"; }
allowed() { local name="$1"; shift; "$@" >/dev/null 2>&1; result $? "$name"; }

[ "$(id -un)" = agent ]; result $? "logged in as agent (uid $(id -u)), groups: $(id -Gn)"
denied "no sudo" sudo -n true
denied "cannot read the cluster's munge key" cat /etc/munge/munge.key
denied "no instance metadata service, so no AWS credentials" \
  curl -fsS -m 5 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token
denied "no direct internet" curl -fsS -m 5 --noproxy '*' -o /dev/null https://example.com
denied "proxy refuses a domain not on the allowlist" curl -fsS -m 10 -o /dev/null https://example.com
allowed "proxy allows an allowlisted domain (UniProt)" \
  curl -fsS -m 30 -o /dev/null https://rest.uniprot.org/uniprotkb/P69905.fasta
denied "cannot cancel the scheduled TTL shutdown" shutdown -c
when=$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
  org.freedesktop.login1.Manager ScheduledShutdown 2>/dev/null | awk '{print $3}')
[ "${when:-0}" -gt 0 ]; result $? "TTL shutdown still scheduled ($(date -u -d "@$(( ${when:-0} / 1000000 ))" +%H:%MZ 2>/dev/null))"
denied "workload code is read-only" touch /shared/opt/ehpc/workloads/.sandbox-check
denied "shared Python environment is read-only" touch /shared/envs/esm/.sandbox-check
allowed "own scratch directory is writable" touch "$SCRATCH/.sandbox-check"

# The same egress checks on every compute node, as Slurm runs agent jobs.
node_check="$SCRATCH/.sandbox-node-check.sh"
cat >"$node_check" <<'NODE'
h=$(hostname)
r() { if [ "$1" = 0 ]; then echo "PASS  $h: $2"; else echo "FAIL  $h: $2"; fi; }
curl -fsS -m 5 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token >/dev/null 2>&1
[ $? != 0 ]; r $? "no instance metadata service"
curl -fsS -m 5 --noproxy '*' -o /dev/null https://example.com >/dev/null 2>&1
[ $? != 0 ]; r $? "no direct internet"
curl -fsS -m 30 -o /dev/null https://rest.uniprot.org/uniprotkb/P69905.fasta >/dev/null 2>&1
r $? "allowlisted domain through the head node's proxy"
timeout 5 bash -c 'exec 3<>/dev/tcp/head/6817' 2>/dev/null
r $? "cluster network open (slurmctld on head:6817)"
[ "$(nproc)" = "$SLURM_CPUS_PER_TASK" ]; r $? "job sees its $SLURM_CPUS_PER_TASK allocated CPUs (nproc $(nproc))"
NODE
out=$(srun --nodes=3 --ntasks-per-node=1 --cpus-per-task=2 bash "$node_check" 2>&1)
echo "$out" | sort
fails=$((fails + $(grep -c '^FAIL' <<<"$out")))
[ "$(grep -c '^PASS' <<<"$out")" = 15 ]; result $? "all three compute nodes answered"
rm -f "$node_check" "$SCRATCH/.sandbox-check"
exit "$fails"
AGENT

  echo
  echo "## As the operator"
  local schedules
  schedules=$(aws_cli scheduler list-schedules --name-prefix ehpc-ttl- \
    --query 'Schedules[].Name' --output text | wc -w | tr -d ' ')
  if [[ "$schedules" -ge 4 ]]; then
    echo "PASS  out-of-instance TTL: $schedules EventBridge schedules"
  else
    echo "FAIL  out-of-instance TTL: $schedules EventBridge schedules"
    agent_fails=$((agent_fails + 1))
  fi
  echo
  echo "## Evidence: denied egress (kernel log) and proxy decisions (squid)"
  ssh "${ssh_opts[@]}" "$admin_alias" \
    'sudo journalctl -k --no-pager -o short-iso | grep ehpc-agent-egress-deny | tail -5 | sed -E "s/ (MAC|SRC|ID|SPT|WINDOW|RES|URGP|TOS|PREC|TTL|LEN)=[^ ]*//g"
     echo; sudo tail -8 /var/log/squid/access.log | awk "{print \$4, \$6, \$7}"'
  return "$agent_fails"
}

if [[ -n "${1:-}" ]]; then
  out="$repo_root/runs/$1"
  mkdir -p "$out"
  set +e
  run_checks | tee "$out/sandbox-check.txt"
  status=${PIPESTATUS[0]}
  set -e
  exit "$status"
fi
run_checks
