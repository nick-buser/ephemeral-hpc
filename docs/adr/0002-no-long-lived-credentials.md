# 0002 No long-lived credentials, and why CI has none

**Status:** accepted, 2026-10-15

## Context

The usual way to apply Terraform from CI without stored keys is GitHub
Actions OIDC federation: GitHub issues a token, and an IAM role trusts
GitHub's identity provider. This account is on AWS's "new experience" sign-up.
There, an AWS-managed service control policy denies `iam:*Provider*`, so the
account cannot create the OIDC identity provider the role would trust. The
same policy blocks EKS IRSA, for the same reason.

Creating an IAM user with access keys for CI would work, and it would put a
long-lived secret in GitHub.

## Decision

- **Applies run from an operator host** with `aws login` session
  credentials. The operator signs in through the browser, and the CLI
  refreshes temporary credentials for up to 12 hours.
  `scripts/tf-run.sh` exports them into the Terraform process only.
- **CI runs every check that needs no AWS account.** That covers fmt,
  validate, the `terraform test` guardrails on a mocked provider, tflint,
  Trivy, gitleaks, ruff, pytest and shellcheck. CI holds no cloud
  credentials at all.
- No IAM users and no access keys exist in the account for this project.

## Consequences

- There is no `terraform plan` comment on pull requests. The mocked-provider
  tests cover the guardrails that matter most.
- If the account's restriction is lifted ("activate advanced features"),
  the next step is a GitHub OIDC role, limited to this repository's `main`
  branch, for plan and apply.
