#!/usr/bin/env bash
# Usage: scripts/verify-api.sh. Check API rejection and live scaling on the lab EKS.
# Example: run after verify.sh; the successful run returns the demo to one replica.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_lab
assert_lab_cluster
actor=system:serviceaccount:idp-lab:developer-demo
mkdir -p "${REPO_DIR}/.local/evidence"

# Usage: reject_patch <JSON> <field>. Require API validation, not a network/RBAC error.
# Server-side dry run avoids changing storage identity if a validation regresses.
reject_patch() {
  local patch="${1}" field="${2}" result
  if result="$(kubectl -n idp-lab patch storageapp/demo --as="${actor}" \
    --dry-run=server --type=merge -p "${patch}" 2>&1)"; then
    fail "Unexpectedly accepted ${field}."
  fi
  [[ "${result}" == *'is invalid'* && "${result}" == *"spec.${field}"* ]] || fail "Unexpected rejection: ${result}"
  printf '%s\n' "${result}"
}

{
  printf 'EKS IDP LAB | %s | API contract | %s\n' "${COMPOSER}" "$(date -u +%FT%TZ)"
  printf '\nServer-side validation as developer-demo\n'
  reject_patch '{"spec":{"storageId":"changed"}}' storageId
  reject_patch '{"spec":{"replicas":0}}' replicas
  reject_patch '{"spec":{"replicas":4}}' replicas
  for replicas in 2 1; do
    printf '\nScale to %s through StorageApp\n' "${replicas}"
    kubectl -n idp-lab patch storageapp/demo --as="${actor}" --type=merge -p "{\"spec\":{\"replicas\":${replicas}}}"
    kubectl -n idp-lab wait --for=jsonpath='{.spec.replicas}'="${replicas}" deployment/storage-demo --timeout=180s
    kubectl -n idp-lab rollout status deployment/storage-demo --timeout=180s
    kubectl -n idp-lab wait --for=jsonpath='{.status.availableReplicas}'="${replicas}" storageapp/demo --timeout=180s
    kubectl -n idp-lab wait --for=condition=Ready storageapp/demo --timeout=180s
    kubectl -n idp-lab get deployment/storage-demo
  done
  printf '\nPASS: immutable storageId, replica limits, and live 1 -> 2 -> 1 scaling.\n'
} 2>&1 | sed "s/${AWS_ACCOUNT_ID}/ACCOUNT_ID/g" | tee "${REPO_DIR}/.local/evidence/api-contract.txt"
