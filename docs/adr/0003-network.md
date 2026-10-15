# 0003 One public subnet, no NAT, one ingress rule

**Status:** accepted, 2026-10-15

## Context

Nodes need outbound internet access at boot for Ubuntu packages, PyPI, the
PyTorch wheel index, ESM-2 weights and the UniProt API. The textbook layout
puts compute nodes in private subnets behind a NAT gateway. A NAT gateway
costs about $0.045/hour (~$33/month) plus per-GB processing charges. For a
cluster that lives a few hours, that is a large share of the total bill.

## Decision

- One public subnet in one availability zone. Single-AZ also keeps
  node-to-node traffic free and low-latency, which matters for DDP.
- Each instance opts in to a public IPv4 address. The subnet does not
  assign one by default.
- **Security groups admit nothing from the internet except TCP 22 to the
  head node from `admin_cidrs`.** `scripts/tf.sh` passes the operator's
  current /32 at apply time. A variable validation rejects anything wider
  than /24, and a `terraform test` case checks that 0.0.0.0/0 is refused.
- Intra-cluster traffic is open between members of the cluster security
  group. Slurm, munge, NFS and gloo all need it.
- Egress is open. The accepted Trivy finding is annotated in
  `infra/network.tf`.
- The VPC's default security group is emptied, and flow logs go to
  CloudWatch Logs with 7-day retention.

## Consequences

- Compute nodes have public addresses with no inbound path to them. The
  security group is the boundary. Private subnets would add a second one.
- Zero inbound ports (Tailscale or SSM-proxied SSH) is on the roadmap. It
  would remove the one remaining rule.
