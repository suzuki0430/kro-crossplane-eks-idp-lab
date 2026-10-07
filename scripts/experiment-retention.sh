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
wait_demo_resources_deleted
aws s3api get-object --bucket "${bucket}" --key uploads/probe.bin "${REPO_DIR}/.local/retained.bin" >/dev/null
cmp "${REPO_DIR}/.local/probe.bin" "${REPO_DIR}/.local/retained.bin"
aws s3api get-public-access-block --bucket "${bucket}" --output json |
  jq -e '.PublicAccessBlockConfiguration|all(.==true)' >/dev/null
aws s3api get-bucket-encryption --bucket "${bucket}" --output json |
  jq -e '.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm=="AES256"' >/dev/null
printf 'PASS: deleted StorageApp; original bytes, public-access block, and AES256 encryption remain.\n' | tee "${REPO_DIR}/.local/retained-before-reconnect.txt"
bash "${REPO_DIR}/scripts/capture-evidence.sh" retained
kubectl apply --as=system:serviceaccount:idp-lab:developer-demo -f "${REPO_DIR}/.local/demo.json"
kubectl -n idp-lab wait --for=condition=Ready storageapp/demo --timeout=600s
# Read the old object through the new pod without uploading it again.
port="${VERIFY_PORT:-18080}"
[[ "${port}" =~ ^[0-9]{4,5}$ ]] || fail 'VERIFY_PORT must be a TCP port.'
kubectl -n idp-lab port-forward service/storage-demo "${port}:80" --address=127.0.0.1 >"${REPO_DIR}/.local/retention-port-forward.log" 2>&1 &
forward_pid=$!
# Usage: stop_forward. Close only this experiment's port-forward on any exit.
stop_forward() { kill "${forward_pid}" 2>/dev/null || true; wait "${forward_pid}" 2>/dev/null || true; }
trap stop_forward EXIT
for _attempt in {1..30}; do
  kill -0 "${forward_pid}" 2>/dev/null || fail 'Retention port-forward exited.'
  if curl --fail --silent --max-time 5 "http://127.0.0.1:${port}/readyz" >/dev/null; then break; fi
  sleep 1
done
curl --fail --silent --show-error --max-time 20 "http://127.0.0.1:${port}/objects/probe.bin" -o "${REPO_DIR}/.local/reconnected.bin"
cmp "${REPO_DIR}/.local/probe.bin" "${REPO_DIR}/.local/reconnected.bin"
printf 'PASS: retained data and protection settings; the new pod read the original bytes via HTTP.\n' | tee "${REPO_DIR}/.local/experiment-retention.txt"
bash "${REPO_DIR}/scripts/capture-evidence.sh" reconnected
