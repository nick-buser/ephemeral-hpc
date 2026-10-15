#!/usr/bin/env bash
# Sign the operator host in to AWS with short-lived console credentials.
#
# This is the one interactive step in the project. `aws login --remote` prints
# a URL; open it in any browser, sign in, and paste the code it shows back
# here. The CLI then refreshes temporary credentials for up to 12 hours.
# No access keys are created or stored.
#
# Runs on the machine named by OPERATOR_HOST (an ssh alias), or locally when
# it is unset. Set it in .operator.env (gitignored) to keep it out of history.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
[[ -f "$repo_root/.operator.env" ]] && source "$repo_root/.operator.env"

profile="${AWS_PROFILE:-ephemeral-hpc}"
region="${AWS_REGION:-us-east-2}"
login="aws configure set region $region --profile $profile \
  && aws login --remote --profile $profile \
  && aws sts get-caller-identity --profile $profile --query Arn --output text"

if [[ -n "${OPERATOR_HOST:-}" ]]; then
  ssh -t "$OPERATOR_HOST" "$login"
else
  bash -c "$login"
fi
