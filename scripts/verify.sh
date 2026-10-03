#!/usr/bin/env bash
# Usage: scripts/verify.sh. Verify actual binary Put/Get, 404, and developer RBAC.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_lab
assert_lab_cluster
require curl cmp
kubectl -n idp-lab wait --for=condition=Ready storageapp/demo --timeout=600s
port="${VERIFY_PORT:-18080}"
[[ "${port}" =~ ^[0-9]{4,5}$ ]] || fail 'VERIFY_PORT must be a TCP port.'
kubectl -n idp-lab port-forward service/storage-demo "${port}:80" --address=127.0.0.1 >"${REPO_DIR}/.local/port-forward.log" 2>&1 &
forward_pid=$!
# Usage: stop_forward. Always close the lab's local port-forward process.
stop_forward() { kill "${forward_pid}" 2>/dev/null || true; wait "${forward_pid}" 2>/dev/null || true; }
trap stop_forward EXIT
for _attempt in {1..30}; do
  kill -0 "${forward_pid}" 2>/dev/null || fail 'Port-forward exited; inspect .local/port-forward.log.'
  if curl --fail --silent --max-time 5 "http://127.0.0.1:${port}/readyz" >/dev/null; then break; fi
  sleep 1
done
curl --fail --silent --show-error --max-time 5 "http://127.0.0.1:${port}/readyz" >/dev/null
printf 'IDP round trip %s\n\000\377\001' "$(date -u +%FT%TZ)" > "${REPO_DIR}/.local/probe.bin"
curl --fail --silent --show-error --max-time 20 -X PUT --data-binary "@${REPO_DIR}/.local/probe.bin" "http://127.0.0.1:${port}/objects/probe.bin"
curl --fail --silent --show-error --max-time 20 "http://127.0.0.1:${port}/objects/probe.bin" -o "${REPO_DIR}/.local/response.bin"
cmp "${REPO_DIR}/.local/probe.bin" "${REPO_DIR}/.local/response.bin"
status="$(curl --silent --show-error --max-time 20 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/objects/missing-$(date +%s)")"
[[ "${status}" == 404 ]] || fail "Missing object returned ${status}, expected 404."
actor=system:serviceaccount:idp-lab:developer-demo
[[ "$(kubectl auth can-i create storageapps.platform.example.com -n idp-lab --as="${actor}")" == yes ]] || fail 'Developer cannot create apps.'
if kubectl auth can-i create roles.iam.aws.m.upbound.io -n idp-lab --as="${actor}" >/dev/null; then fail 'Developer can create raw IAM roles.'; fi
if kubectl auth can-i patch configmaps -n idp-lab --as="${actor}" >/dev/null; then fail 'Developer can alter platform settings.'; fi
printf 'PASS: binary round trip, missing-object handling, and developer permissions.\n' | tee "${REPO_DIR}/.local/verify.txt"
bash "${REPO_DIR}/scripts/capture-evidence.sh" ready
