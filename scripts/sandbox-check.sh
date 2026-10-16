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

# The checks that run on the cluster as the agent. Quoted heredoc: nothing
# here expands on the operator's machine.
agent_checks() {
  cat <<'AGENT'
set -u
source /etc/profile.d/ehpc.sh
fails=0
result() { if [ "$1" = 0 ]; then echo "PASS  $2"; else echo "FAIL  $2"; fails=$((fails + 1)); fi; }
denied() { local name="$1"; shift; "$@" >/dev/null 2>&1; [ $? != 0 ]; result $? "$name"; }
allowed() { local name="$1"; shift; "$@" >/dev/null 2>&1; result $? "$name"; }

[ "$(id -un)" = agent ]; result $? "logged in as agent (uid $(id -u)), groups: $(id -Gn)"
denied "no sudo" sudo -n true
denied "cannot read the cluster's munge key" cat /etc/munge/munge.key
denied "no subordinate UID/GID range for the agent" grep -qs '^agent:' /etc/subuid /etc/subgid
denied "newuidmap/newgidmap are not setuid" test -u /usr/bin/newuidmap -o -u /usr/bin/newgidmap
denied "firewall: no instance metadata service, so no AWS credentials" \
  curl -fsS -m 5 --noproxy '*' -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token
denied "proxy: will not forward to the metadata service either" \
  curl -fsS -m 5 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token
denied "firewall: no direct internet" curl -fsS -m 5 --noproxy '*' -o /dev/null https://example.com
denied "proxy: refuses a domain not on the allowlist" curl -fsS -m 10 -o /dev/null https://example.com
denied "proxy: refuses a bare IP (no reverse-DNS match)" curl -fsS -m 10 -o /dev/null https://1.1.1.1
denied "proxy: refuses PyPI (shared CDN, not on the allowlist)" curl -fsS -m 10 -o /dev/null https://pypi.org/simple/
allowed "proxy: allows an allowlisted domain (UniProt)" \
  curl -fsS -m 30 -o /dev/null https://rest.uniprot.org/uniprotkb/P69905.fasta
denied "cannot cancel the scheduled TTL shutdown" shutdown -c
when=$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
  org.freedesktop.login1.Manager ScheduledShutdown 2>/dev/null | awk '{print $3}')
[ "${when:-0}" -gt 0 ]; result $? "TTL shutdown still scheduled ($(date -u -d "@$(( ${when:-0} / 1000000 ))" +%H:%MZ 2>/dev/null))"
denied "workload code is read-only" touch /shared/opt/ehpc/workloads/.sandbox-check
denied "container image is read-only" touch /shared/containers/esm.sif
allowed "own scratch directory is writable" touch "$SCRATCH/.sandbox-check"

# The same egress checks on every compute node, as Slurm runs agent jobs.
node_check="$SCRATCH/.sandbox-node-check.sh"
cat >"$node_check" <<'NODE'
h=$(hostname)
r() { if [ "$1" = 0 ]; then echo "PASS  $h: $2"; else echo "FAIL  $h: $2"; fi; }
curl -fsS -m 5 --noproxy '*' -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token >/dev/null 2>&1
[ $? != 0 ]; r $? "firewall: no instance metadata service"
curl -fsS -m 5 --noproxy '*' -o /dev/null https://example.com >/dev/null 2>&1
[ $? != 0 ]; r $? "firewall: no direct internet"
curl -fsS -m 30 -o /dev/null https://rest.uniprot.org/uniprotkb/P69905.fasta >/dev/null 2>&1
r $? "allowlisted domain through the head node's proxy"
timeout 5 bash -c 'exec 3<>/dev/tcp/head/6817' 2>/dev/null
r $? "cluster network open (slurmctld on head:6817)"
! grep -qs '^agent:' /etc/subuid /etc/subgid && [ ! -u /usr/bin/newuidmap ]
r $? "no subordinate IDs, newuidmap not setuid"
[ "$(nproc)" = "$SLURM_CPUS_PER_TASK" ]; r $? "job sees its $SLURM_CPUS_PER_TASK allocated CPUs (nproc $(nproc))"
NODE
# </dev/null: srun forwards stdin, and stdin here is the rest of this script.
out=$(srun --nodes=3 --ntasks-per-node=1 --cpus-per-task=2 bash "$node_check" 2>&1 </dev/null)
echo "$out" | sort
fails=$((fails + $(grep -c '^FAIL' <<<"$out")))
[ "$(grep -c '^PASS' <<<"$out")" = 18 ]; result $? "all three compute nodes answered"

# And inside the Apptainer image every job runs in ($EHPC_PY).
ctr_check="$SCRATCH/.sandbox-container-check.py"
cat >"$ctr_check" <<'PY'
import os, socket, urllib.request as u
h = socket.gethostname()
def r(ok, name): print(("PASS" if ok else "FAIL") + f"  {h} (container): {name}")
def denied(f):
    try:
        f()
        return False
    except Exception:
        return True
direct = u.build_opener(u.ProxyHandler({}))
imds = u.Request("http://169.254.169.254/latest/api/token", method="PUT",
                 headers={"X-aws-ec2-metadata-token-ttl-seconds": "60"})
r(denied(lambda: direct.open(imds, timeout=5)), "no instance metadata service")
r(denied(lambda: direct.open("https://example.com", timeout=5)), "no direct internet")
r(not denied(lambda: u.urlopen("https://rest.uniprot.org/uniprotkb/P69905.fasta", timeout=30)), "allowlisted domain through the proxy")
r(os.listdir(os.path.expanduser("~")) == [], "private, empty home")
r(not os.path.exists("/etc/munge"), "host /etc not visible")
r(open("/proc/1/cmdline").read().startswith("appinit"), "own PID namespace")
r(denied(lambda: open("/opt/ehpc/requirements.txt", "a")), "image is read-only")
PY
out=$(srun --nodes=3 --ntasks-per-node=1 --cpus-per-task=2 "$EHPC_PY" "$ctr_check" 2>&1 </dev/null)
echo "$out" | sort
fails=$((fails + $(grep -c '^FAIL' <<<"$out")))
[ "$(grep -c '^PASS' <<<"$out")" = 21 ]; result $? "all three compute nodes answered from inside the container"
rm -f "$node_check" "$ctr_check" "$SCRATCH/.sandbox-check"
echo "checks-complete"
exit "$fails"
AGENT
}

run_checks() {
  echo "# sandbox check, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "## As the agent, on the head node and each compute node"
  local agent_fails=0 agent_out
  agent_out=$(agent_checks | ssh "${ssh_opts[@]}" "$agent_alias" 'bash -s' 2>&1) || agent_fails=$?
  # A check that stops early must not read as a pass.
  grep -v '^checks-complete$' <<<"$agent_out"
  if ! grep -q '^checks-complete$' <<<"$agent_out"; then
    echo "FAIL  agent checks stopped before the end"
    agent_fails=$((agent_fails + 1))
  fi

  echo
  echo "## As the operator"
  local names schedules
  if ! names=$(aws_cli scheduler list-schedules --name-prefix ehpc-ttl- \
    --query 'Schedules[].Name' --output text 2>&1); then
    echo "FAIL  out-of-instance TTL: could not query EventBridge (${names##*: })"
    agent_fails=$((agent_fails + 1))
  else
    schedules=$(wc -w <<<"$names" | tr -d ' ')
    if [[ "$schedules" -ge 4 ]]; then
      echo "PASS  out-of-instance TTL: $schedules EventBridge schedules"
    else
      echo "FAIL  out-of-instance TTL: $schedules EventBridge schedules"
      agent_fails=$((agent_fails + 1))
    fi
  fi
  if ssh "${ssh_opts[@]}" "$admin_alias" 'sudo nft list chain inet ehpc_agent output' | grep -q '100000-4294967294'; then
    echo "PASS  egress rules also cover subordinate UIDs (100000 and up)"
  else
    echo "FAIL  egress rules also cover subordinate UIDs (100000 and up)"
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
