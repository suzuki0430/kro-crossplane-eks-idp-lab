#!/usr/bin/env bash
# Usage: scripts/experiment-retention.sh. Delete the demo, verify retained bytes, then reconnect.
# Run verify.sh first. This deletes only the test StorageApp; S3 deletion is never requested.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_lab
assert_lab_cluster
[[ -f "${REPO_DIR}/.local/probe.bin" ]] || fail 'Run scripts/verify.sh first.'
bucket="idplab-${AWS_ACCOUNT_ID}-${LAB_ID}-demo"
kubectl -n idp-lab delete storageapp/demo --wait=true --timeout=600s
aws s3api get-object --bucket "${bucket}" --key uploads/probe.bin "${REPO_DIR}/.local/retained.bin" >/dev/null
cmp "${REPO_DIR}/.local/probe.bin" "${REPO_DIR}/.local/retained.bin"
aws s3api get-public-access-block --bucket "${bucket}" --output json |
  jq -e '.PublicAccessBlockConfiguration|all(.==true)' >/dev/null
aws s3api get-bucket-encryption --bucket "${bucket}" --output json |
  jq -e '.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm=="AES256"' >/dev/null
kubectl apply --as=system:serviceaccount:idp-lab:developer-demo -f "${REPO_DIR}/.local/demo.json"
kubectl -n idp-lab wait --for=condition=Ready storageapp/demo --timeout=600s
printf 'PASS: app deletion retained data and protection settings; the same storageId reconnected.\n' | tee "${REPO_DIR}/.local/experiment-retention.txt"
