#!/usr/bin/env bash
# Runs on the operator host (called by scripts/tf.sh). Exchanges the cached
# `aws login` session for temporary credentials, initialises the stack's
# backend, and runs terraform. Credentials live only in this process.
set -euo pipefail

stack="$1"
shift
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root/$stack"

eval "$(aws configure export-credentials --profile "$AWS_PROFILE" --format env)"
unset AWS_PROFILE # terraform should use the exported temporary credentials

if [[ "$stack" == infra ]]; then
  account_id="$(aws sts get-caller-identity --query Account --output text)"
  backend_bucket="ehpc-tfstate-${account_id}-${AWS_REGION}"
  if [[ ! -d .terraform ]] || ! grep -q "$backend_bucket" .terraform/terraform.tfstate 2>/dev/null; then
    terraform init -input=false -reconfigure \
      -backend-config="bucket=${backend_bucket}" \
      -backend-config="region=${AWS_REGION}" >&2
  fi
else
  [[ -d .terraform ]] || terraform init -input=false >&2
fi

terraform "$@"
