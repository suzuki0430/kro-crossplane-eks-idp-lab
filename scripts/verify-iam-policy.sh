#!/usr/bin/env bash
# Usage: scripts/verify-iam-policy.sh. Evaluate provider IAM guardrails with AWS's simulator.
# This is policy simulation, not a substitute for calls made with real Pod Identity credentials.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_lab
source_arn="arn:aws:iam::${AWS_ACCOUNT_ID}:role/idplab-${LAB_ID}-provider-iam"
root_role="arn:aws:iam::${AWS_ACCOUNT_ID}:role/idplab-${LAB_ID}-demo"
workload_role="arn:aws:iam::${AWS_ACCOUNT_ID}:role/idplab/${LAB_ID}/workloads/idplab-${LAB_ID}-demo"
other_role="arn:aws:iam::${AWS_ACCOUNT_ID}:role/idplab-unrelated-demo"
boundary="$(bootstrap_output BoundaryArn)"
context="$(jq -cn --arg arn "${boundary}" '[{ContextKeyName:"iam:PermissionsBoundary",ContextKeyValues:[$arn],ContextKeyType:"string"}]')"

# Usage: expect_decision <action> <resource> <expected> [AWS CLI context arguments].
# Example: expect_decision iam:GetRole "$root_role" allowed.
# Fail on any unexpected permission expansion or missing required permission.
expect_decision() {
  local action="${1}" resource="${2}" expected="${3}" actual
  shift 3
  actual="$(aws iam simulate-principal-policy --policy-source-arn "${source_arn}" \
    --action-names "${action}" --resource-arns "${resource}" "$@" \
    --query 'EvaluationResults[0].EvalDecision' --output text)"
  [[ "${actual}" == "${expected}" ]] || fail "${action}: expected ${expected}, got ${actual}."
  printf 'PASS (IAM simulation): %-36s %-12s %s\n' "${action}" "${actual}" "${resource}"
}

{
  expect_decision iam:GetRole "${root_role}" allowed
  expect_decision iam:GetRole "${workload_role}" allowed
  expect_decision iam:GetRole "${other_role}" implicitDeny
  expect_decision iam:CreateRole "${workload_role}" allowed --context-entries "${context}"
  expect_decision iam:CreateRole "${workload_role}" implicitDeny
  expect_decision iam:CreateRole "${root_role}" implicitDeny --context-entries "${context}"
  expect_decision iam:DeleteRolePermissionsBoundary "${workload_role}" implicitDeny
} | sed "s/${AWS_ACCOUNT_ID}/ACCOUNT_ID/g" | tee "${REPO_DIR}/.local/iam-policy-simulation.txt"
