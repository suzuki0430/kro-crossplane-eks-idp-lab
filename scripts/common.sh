#!/usr/bin/env bash
# Shared helpers. Source this file from another script; do not execute it directly.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_DIR
# shellcheck source=../versions.env
source "${REPO_DIR}/versions.env"

# Usage: fail <message>. Print a non-secret error and exit with status 1.
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Usage: require <command> [...]. Fail before making any changes if tools are absent.
require() {
  local command_name
  for command_name in "$@"; do
    command -v "${command_name}" >/dev/null || fail "Install ${command_name} first."
  done
}

# Usage: load_lab. Load local settings, enforce account/region, and isolate kubeconfig.
# Example: AWS_PROFILE=my-sso, EXPECTED_ACCOUNT_ID=123456789012 in .env.
load_lab() {
  require aws jq kubectl
  [[ -f "${REPO_DIR}/.env" ]] || fail 'Copy .env.example to .env and fill in its values.'
  set -a
  # shellcheck source=/dev/null
  source "${REPO_DIR}/.env"
  set +a
  : "${AWS_PROFILE:?AWS_PROFILE is required}" "${AWS_REGION:?AWS_REGION is required}"
  : "${LAB_ID:?LAB_ID is required}" "${EXPECTED_ACCOUNT_ID:?EXPECTED_ACCOUNT_ID is required}"
  [[ "${LAB_ID}" =~ ^[a-z0-9]{6,12}$ ]] || fail 'LAB_ID must be 6-12 lowercase letters/digits.'
  [[ "${EXPECTED_ACCOUNT_ID}" =~ ^[0-9]{12}$ ]] || fail 'Invalid EXPECTED_ACCOUNT_ID.'
  [[ "${AWS_REGION}" =~ ^[a-z]{2}-[a-z]+-[0-9]+$ ]] || fail 'Use a commercial AWS region.'
  export AWS_DEFAULT_REGION="${AWS_REGION}" AWS_PAGER=''
  AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
  [[ "${AWS_ACCOUNT_ID}" == "${EXPECTED_ACCOUNT_ID}" ]] || fail 'AWS account mismatch; refusing changes.'
  export AWS_ACCOUNT_ID
  export CLUSTER_NAME="idplab-${LAB_ID}" BOOTSTRAP_STACK="idplab-${LAB_ID}-bootstrap"
  export KUBECONFIG="${REPO_DIR}/.local/kubeconfig"
  mkdir -p "${REPO_DIR}/.local"
  chmod 700 "${REPO_DIR}/.local"
}

# Usage: assert_lab_cluster. Verify this cluster was created by this lab before mutation.
assert_lab_cluster() {
  local cluster
  cluster="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --output json)"
  [[ "$(jq -r '.cluster.tags.ManagedBy' <<<"${cluster}")" == 'kro-crossplane-idp-lab' ]] || fail 'Cluster ownership tag mismatch.'
  [[ "$(jq -r '.cluster.tags.LabId' <<<"${cluster}")" == "${LAB_ID}" ]] || fail 'Cluster LabId mismatch.'
  aws eks update-kubeconfig --name "${CLUSTER_NAME}" --kubeconfig "${KUBECONFIG}" --alias "${CLUSTER_NAME}" >/dev/null
}

# Usage: bootstrap_output <key>. Read one non-secret CloudFormation output.
bootstrap_output() {
  aws cloudformation describe-stacks --stack-name "${BOOTSTRAP_STACK}" --output json |
    jq -er --arg key "${1:?Output key required}" '.Stacks[0].Outputs[] | select(.OutputKey==$key) | .OutputValue'
}
