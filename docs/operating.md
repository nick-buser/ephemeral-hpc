# Operating the cluster

## Once per machine

- An operator host with AWS CLI ≥ 2.32 (for `aws login`) and Terraform ≥ 1.10.
  It can be the machine you work on. Set `OPERATOR_HOST=<ssh alias>` in
  `.operator.env` (gitignored) to run Terraform somewhere else over SSH.
- A dedicated SSH key: `ssh-keygen -t ed25519 -f ~/.ssh/ehpc_ed25519`.
- `EHPC_ALERT_EMAIL=<you@example.com>` in `.operator.env` for budget alerts.

## Once per 12 hours

```
scripts/operator-login.sh
```

It prints a sign-in URL. Open it in a browser, sign in, and paste the code
back. No access keys are created.

## Once per account

```
scripts/tf.sh bootstrap apply
```

This creates the state bucket `ehpc-tfstate-<account>-<region>` and the
monthly budget. Bootstrap state stays local on the operator host.

## Spending limits

The account's plan sets the hard limit. Check which plan the account is on:

```
aws freetier get-account-plan-state --region us-east-1
```

- **Free plan.** AWS cannot charge the card. Usage draws down the sign-up
  credit, and the account closes when the credit is spent or the plan
  expires. Nothing to configure.
- **Paid plan.** Set a spend limit in the console: settings.aws.com →
  Billing → Cost by project → Spend limit → Set limit. The minimum is $20.
  Also tick "Stop new resource launches". At the limit AWS pauses the
  project and stops its resources; data is kept for 90 days. Spend limits
  have no API, so they are not in Terraform.

Neither limit is real-time. Both run on billing data, which lags by hours.
The limits that act within minutes are in the stack itself: every node
powers off after `ttl_hours` and powering off terminates it, idle nodes are
terminated by alarm, root volumes are deleted with their node, and there is
no NAT gateway. The bootstrap budget emails at 50%, 80% and 100% of $20.

## Each session

```
scripts/tf.sh infra apply
scripts/ssh-config.sh
```

`apply` returns in about a minute. The nodes then take about 5–8 minutes to
install packages, build the Python environment on `/shared` and join Slurm.
`ssh-config.sh` writes `Host ehpc` into `~/.ssh/config` and prints `sinfo`.
All three compute nodes should show `idle`.

Progress on any node: `sudo tail -f /var/log/ehpc-init.log`. The head node
writes `/shared/.ready` when its Python environment and model weights are
in place.

## Run the workflow by hand

```
ssh ehpc
/shared/opt/ehpc/workloads/protein/pipeline.sh
squeue; sacct
```

To run it through Claude Science instead, see [claude-science.md](claude-science.md).

## Tear down

```
scripts/tf.sh infra destroy
```

If you forget, every node powers off `ttl_hours` (default 4) after boot,
and powering off terminates it. A node idle for `idle_minutes` (default 60)
is terminated by its CloudWatch alarm. `terraform apply` rebuilds anything
that has gone. `destroy` cleans up the VPC, IAM roles and alarms, which cost
nothing while idle but should not linger.

## Changing the shape

| Variable | Default | Notes |
|---|---|---|
| `compute_count` | 3 | 1–8 nodes |
| `compute_instance_type` | `m7i-flex.large` | Slurm CPUs and memory follow the instance type automatically |
| `head_instance_type` | `t3.small` | Runs slurmctld, slurmdbd, MariaDB, NFS |
| `ttl_hours` | 4 | Also the partition's MaxTime |
| `idle_minutes` | 60 | Multiple of 5 |

Pass them as `TF_VAR_<name>` or `-var` through `scripts/tf.sh`.
