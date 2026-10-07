#!/usr/bin/env bash
# Usage: scripts/experiment-failure.sh. Temporarily deny the lab app's health writes.
# An EXIT trap removes only this experiment's inline policy, including on interruption.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_lab
assert_lab_cluster
role_name="idplab-${LAB_ID}-demo"
role="$(aws iam get-role --role-name "${role_name}" --output json)"
[[ "$(jq -r '.Role.Path' <<<"${role}")" == "/idplab/${LAB_ID}/workloads/" ]] || fail 'Wrong role path.'
[[ "$(jq -r '.Role.Tags[] | select(.Key=="LabId") | .Value' <<<"${role}")" == "${LAB_ID}" ]] || fail 'Wrong role tag.'
policy_name=idplab-deny-health-probe
kubectl -n idp-lab wait --for=condition=Ready storageapp/demo --timeout=300s
# Usage: restore_permission. Remove the test policy; propagate cleanup failures.
restore_permission() { aws iam delete-role-policy --role-name "${role_name}" --policy-name "${policy_name}"; }
trap restore_permission EXIT
jq -n --arg resource "arn:aws:s3:::idplab-${AWS_ACCOUNT_ID}-${LAB_ID}-demo/_health/*" \
  '{Version:"2012-10-17",Statement:[{Effect:"Deny",Action:"s3:PutObject",Resource:$resource}]}' > "${REPO_DIR}/.local/deny-probe.json"
aws iam put-role-policy --role-name "${role_name}" --policy-name "${policy_name}" --policy-document "file://${REPO_DIR}/.local/deny-probe.json"
kubectl -n idp-lab wait --for=condition=Ready=false storageapp/demo --timeout=240s
kubectl -n idp-lab get storageapp/demo -o yaml > "${REPO_DIR}/.local/experiment-failure.yaml"
kubectl -n idp-lab logs deployment/storage-demo --tail=30 > "${REPO_DIR}/.local/experiment-failure.log"
bash "${REPO_DIR}/scripts/capture-evidence.sh" failure
restore_permission
trap - EXIT
kubectl -n idp-lab wait --for=condition=Ready storageapp/demo --timeout=240s
printf 'PASS: denied S3 writes made Ready=False; removing the denial restored Ready=True.\n' | tee "${REPO_DIR}/.local/experiment-failure.txt"
bash "${REPO_DIR}/scripts/capture-evidence.sh" recovered
