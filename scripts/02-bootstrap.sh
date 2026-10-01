#!/usr/bin/env bash
# Usage: scripts/02-bootstrap.sh. Create bounded controller roles and an ECR repository.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_lab
assert_lab_cluster
aws cloudformation validate-template --template-body "file://${REPO_DIR}/infrastructure/bootstrap.yaml" >/dev/null
aws cloudformation deploy --stack-name "${BOOTSTRAP_STACK}" \
  --template-file "${REPO_DIR}/infrastructure/bootstrap.yaml" \
  --parameter-overrides "LabId=${LAB_ID}" --capabilities CAPABILITY_NAMED_IAM \
  --tags ManagedBy=kro-crossplane-idp-lab "LabId=${LAB_ID}" --no-fail-on-empty-changeset
aws cloudformation describe-stacks --stack-name "${BOOTSTRAP_STACK}" --query 'Stacks[0].Outputs' --output json > "${REPO_DIR}/.local/bootstrap-outputs.json"
