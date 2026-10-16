# Agent isolation: what we built, what broke, and what Apptainer adds

Study notes from 2026-10-16, written while hardening the cluster after the
first Claude Science run. The decisions are in [ADR 0006](../adr/0006-agent-sandbox.md)
and [ADR 0007](../adr/0007-apptainer.md); this file keeps the reasoning,
the mistakes and the concepts, so they can be learned from later.

## The question

"Were the nodes sandboxed?" No. The network kept the internet out, but
nothing kept the agent in. Claude Science logged in as `ubuntu`, which has
passwordless sudo, so every job it wrote ran with root available.

The threat model is modest. The data is public UniProt sequences. The real
risks are cost (a runaway job on an account with a card behind it), the
AWS account (credentials on the node), using the cluster to reach other
hosts, and tampering with the run record. A human approves each job card,
but an approval is a person skimming a script, not a boundary.

## What we built, layer by layer

| Layer | Mechanism | What it stops | Proven by (`sandbox-check.sh`) |
|---|---|---|---|
| Machine | One EC2 VM per node; the only hard isolation boundary | Escaping to other tenants or other machines | (AWS's guarantee) |
| Network | Dedicated VPC, no peering; inbound SSH only from the operator's /32 | Reaching the homelab, laptop or other AWS resources | flow logs |
| Account | Instance roles limited to one SSM path; EventBridge TTL outside the instances | Using the account; keeping nodes alive past the TTL | `out-of-instance TTL: 4 EventBridge schedules` |
| Identity | `agent` user, own key, no sudo, no subordinate UIDs; `newuidmap` not setuid; operator keeps `ubuntu` | Root; becoming any other host UID; editing code, image, firewall or Slurm config; reading the munge key | `no sudo`, `no subordinate UID/GID range`, `newuidmap/newgidmap are not setuid`, `cannot read the cluster's munge key` |
| Egress | nftables, matched on the packet owner's UID (the agent's, and every subordinate UID): loopback and VPC only | AWS credentials (IMDS); direct internet | `firewall: …`, `egress rules also cover subordinate UIDs` |
| Proxy | Squid allowlist, UniProt only, every request logged | Any site not on the list | `proxy: refuses …`, `proxy: allows …` |
| Container | Apptainer `--contain --ipc --pid`, read-only image | Seeing the host filesystem and processes; changing the runtime | the 21 `(container)` checks |
| Resources | Slurm cgroups | One job starving a node | `job sees its 2 allocated CPUs` |

Two design rules came out of this:

1. **Guardrails belong outside the blast radius.** A TTL scheduled inside
   the OS can be cancelled by whoever is root there. A CPU-idle alarm
   cannot see a busy runaway job. The TTL that matters runs in EventBridge.
2. **Test each layer alone.** Layers overlap, so a request blocked by one
   layer says nothing about the layer you meant to test (finding 5).

## What we found, in order

Each entry: what we saw, why, the fix, and the general lesson.

1. **The default cloud user is an admin.** Ubuntu's `ubuntu` user has
   passwordless sudo via cloud-init. *Lesson:* never hand an agent the
   image's default user; create one with no privileges.
2. **Root can disarm in-OS guardrails.** `shutdown -c` cancels the TTL; the
   idle alarm only fires on low CPU. *Fix:* EventBridge Scheduler
   terminates each node from outside. *Lesson:* see design rule 1.
3. **AWS-managed policies are broader than their names.**
   `AmazonSSMManagedInstanceCore` grants `ssm:GetParameter` on `*`, so any
   node could read every parameter in the account (SecureStrings
   included, via the default key). Nothing used it. *Fix:* removed.
4. **A check that skips itself passes.** The first `sandbox-check.sh` never
   reached the compute nodes yet exited 0: `srun` forwards stdin, stdin
   was the rest of the script piped over SSH, and `srun` consumed it.
   *Fix:* `</dev/null`, plus a completion marker the runner requires.
   *Lesson:* checks must fail closed; count what you expected to run.
5. **A pass for the wrong reason.** The metadata-service check passed
   because the agent's `https_proxy` sent the request to Squid, which
   refused it; the firewall was never exercised. *Fix:* test with
   `--noproxy '*'` and through the proxy, separately.
6. **Negated matches on optional metadata.** The first nft rule was
   `meta skuid != 2001 accept`. Packets the kernel sends with no owning
   socket (IPv6 multicast reports, some resets) have no UID, the
   comparison cannot match, and they fell through to `reject`; the deny
   log showed `ff02::16`. *Fix:* match positively (`meta skuid 2001 jump
   agent`). *Lesson:* "not X" is not the same as "no X".
7. **Name allowlists must not trust reverse DNS.** For a request to a bare
   IP, Squid's `dstdomain` looks up the IP's PTR record. Whoever owns an
   IP controls its PTR, so they could name it `files.pythonhosted.org`.
   *Fix:* `dstdomain -n`, and link-local and localhost denied explicitly.
8. **Tracing is logging.** `set -x` in the boot script wrote the IMDSv2
   session token into the boot log, which went into the committed run
   record. CI's gitleaks caught it. The token was link-local and expired
   after 60 s, so nothing leaked in practice. *Fix:* no tracing around the
   token; the harvest script redacts and refuses. *Side finding:* on push,
   gitleaks scans only the new commits, so the README's "full-history
   scan" was untrue until a scheduled run was added.
9. **Containers cut you off from host tools.** The trainer called
   `scontrol` for its rendezvous host; `scontrol` is not in the image.
   *Fix:* parse the Slurm hostlist in Python. *Lesson:* pass information
   in through the environment, not host binaries.
10. **Limits you forget exist.** EC2 user data is capped at 16 KiB. Head
    user data reached 16,614 bytes; the guardrail test caught it before
    EC2 did. Cause: files gzipped one by one, then gzipped again as part
    of the whole, which gains nothing. *Fix:* plain text inside, one gzip
    pass: 14,712 bytes.
11. **Implicit coupling in IaC.** Replacing the head left the compute nodes
    as in-place updates, still holding the old munge key and an NFS mount
    to a dead head. Their user data names the head's ID, unknown at plan
    time, so `user_data_replace_on_change` never fired. *Fix:*
    `replace_triggered_by = [aws_instance.head.id]`.
12. **Accounting is observability.** (From the first run.) `sacct` showed
    every embedding step using 50% of its CPU time. Slurm had been told
    `CPUs=2` with no topology and pinned each job to one of the two
    hyperthreads. Declaring the topology gave +21%.
13. **Idle detection versus human latency.** (From the first run.) An
    agent waiting on a human approval looks idle to a CPU alarm. The
    cluster terminated itself twice before a job arrived.
14. **"Built from the same definition" is not "the same bytes".** The
    image built by hand and the one built at boot hash differently
    (timestamps inside the SIF). The contents match; the checksum does
    not. A build-once-in-CI image, pulled by digest, would make the
    checksum mean something across clusters.
15. **Unprivileged does not mean "cannot build".** As `agent`, `apptainer
    build` from the cluster's own image ran its `%post` step as "root":
    root inside a user namespace, with no power on the host (the process
    is still UID 2001, so the firewall still applies). The agent can make
    derived images from local ones, and pip-install through the proxy
    while doing it. It cannot pull a new base: no registry is allowlisted.

16. **Secret patterns meet biology.** The harvest's secret scan refused a
    dataset file: a protein sequence contains `ASIA` followed by 16
    capital letters, the shape of an AWS temporary key ID. Real key IDs
    have boundaries on both sides; the pattern now requires them (gitleaks
    already did), and datasets no longer enter the record at all.

17. **An identity-based rule is only as good as the identity.** The
    egress rules matched UID 2001 on the assumption that the agent could
    only ever be UID 2001. It could not become root, but `useradd` had
    given it a subordinate UID range, and Apptainer's `uidmap` dependency
    installs a setuid `newuidmap` that honours those ranges. Inside a
    `--fakeroot` container the agent could therefore run processes under
    other host UIDs, which the rules did not match. An independent review
    found this; it was confirmed on the live cluster; my own check had
    missed it because it only ever tested UID 2001. *Fix:* three layers:
    no subordinate ranges (set before any user is created), no setuid bit
    on `newuidmap`/`newgidmap`, and rules that also match UIDs 100000 and
    up. *Lessons:* list every way a process can change identity before
    trusting an identity-based control; test the property ("nothing the
    agent starts gets out"), not one instance of it; and get someone else
    to attack your sandbox.
18. **A CONNECT proxy sees the name you ask for, not the site you get.**
    Squid allowlisted `CONNECT download.pytorch.org:443`, but the TLS
    handshake inside the tunnel names its own server. On a shared CDN
    edge (CloudFront, Fastly) those can differ, so an allowlisted CDN
    hostname is close to allowing the whole CDN. *Fix:* allow only what
    the agent needs at run time; packages and weights are already in the
    image, so that is UniProt, which has a dedicated address.
19. **`find -size -1M` matches only empty files.** It rounds sizes up to
    whole MiB. Found when the hardened harvest came back empty.
20. **`set -e` ignores negated commands.** `! grep -q pattern file` cannot
    fail a `set -e` script, so a guard written that way guards nothing.
    Caught in review of my own fix before it shipped.

## Our host controls versus Apptainer

Apptainer is a packaging and namespace tool. It changes what a job can
*see* and makes the runtime a single portable artifact. It does not
change what a job can *reach* or *who* it runs as. That is why the two
compose: the container process keeps the agent's UID, so the host's
UID-based firewall applies inside it unchanged. That holds only while the
agent cannot map itself to other UIDs; finding 17 is what happened when
it could.

| Concern | Host controls alone (ADR 0006) | What Apptainer adds (ADR 0007) | Still uncovered |
|---|---|---|---|
| Privilege | Unprivileged `agent`, no sudo | Runs as the same user in a user namespace. Its package depends on `uidmap`, a setuid helper that can map other UIDs; boot removes the setuid bit and the agent's subordinate ranges | Shared kernel |
| Filesystem view | Unix permissions only; world-readable host files are visible | Host `/etc`, `/home`, `/tmp` out of view; empty private home; image read-only | `/shared` is visible by design |
| Processes | `ps` shows every process on the node | Own PID namespace: sees only itself | |
| Network | nftables per UID, proxy allowlist | Nothing: it shares the host's network namespace | DNS lookups as an exfiltration path |
| AWS credentials | IMDS blocked by nftables | Nothing | |
| Software environment | Mutable venv on NFS, built per cluster | One immutable image: base pinned by digest, packages pinned, weights inside; runs on any Apptainer host | Package hashes not pinned; image not signed |
| Reproducibility | Same requirements, rebuilt each time | Same artifact; checksum recorded per cluster | Rebuilt per cluster until CI builds it once |
| Resource limits | Slurm cgroups | Nothing extra | |
| Kernel attack surface | Standard | *Wider*: user namespaces expose more kernel code to unprivileged users, which is why Ubuntu 24.04 restricts them. Apptainer's AppArmor profile re-allows them for Apptainer only | Needs gVisor or microVMs |
| Enforcement | n/a | Nothing forces a job into the container | Slurm OCI support or a job-submit plugin |

Measured: no throughput cost (1,795.6 vs 1,773.2 residues/s, same node
and data), 0.21 s startup (squashfuse mount), 393 s image build on the
head at boot.

## Concepts worth studying

- **IMDSv2.** The instance metadata service hands out the node's role
  credentials. v2 requires a PUT for a session token; hop limit 1 keeps
  containers in their own network namespace away from it. Here the
  agent shares the host namespace, so the firewall does that job.
- **User namespaces.** Let an unprivileged process be "root" inside a
  namespace with no power outside it. Basis of rootless containers, and
  a recurring source of kernel CVEs. See
  `kernel.apparmor_restrict_unprivileged_userns` on Ubuntu 24.04.
- **setuid versus non-setuid Apptainer.** The setuid build can enforce
  `apptainer.conf` policy (allowed image paths, owners) because a root
  helper mediates. The non-setuid build cannot, but has no root helper to
  attack.
- **SIF and squashfuse.** A SIF is a single file holding a compressed
  squashfs filesystem plus metadata and optional signatures. Unprivileged
  Apptainer mounts it through FUSE instead of unpacking it.
- **nftables owner match and conntrack.** `meta skuid` matches the UID of
  the socket that sent a packet (output path only). `ct state
  established,related` lets replies through for connections opened *to*
  the agent, such as its own SSH session.
- **Forward proxies.** HTTPS through a proxy is a `CONNECT host:443`
  tunnel; the proxy sees the hostname, not the content. Allowlisting by
  name is the practical control; `dstdomain -n` keeps it name-only.
- **Slurm details that bit.** Configless mode (`--conf-server`), cgroup
  `ConstrainCores`, node topology (`CoresPerSocket`, `ThreadsPerCore`),
  hostlist expressions (`compute-[1-3]`), and `srun` forwarding stdin.
- **Guardrails outside the blast radius.** EventBridge Scheduler
  "universal targets" call any AWS API on a schedule, here
  `ec2:TerminateInstances`, through a role scoped by tag.

## Open items

- Build the image once in CI, sign it, and pull it by digest instead of
  building on every head node.
- Take the compute nodes off the public internet (prebuilt AMI, or VPC
  endpoints plus the proxy for apt).
- Force jobs into the container (Slurm OCI support or a job-submit plugin).
- Close DNS as an exfiltration path (Route 53 Resolver DNS Firewall).
- Check the TLS server name at the proxy (squid `ssl_bump peek` and
  `splice`), so a shared-CDN host could go back on the allowlist safely.

Reproduce every claim above on a live cluster:

```
scripts/sandbox-check.sh
```
