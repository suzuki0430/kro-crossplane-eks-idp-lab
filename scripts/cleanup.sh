#!/usr/bin/env bash
# Usage: scripts/cleanup.sh. Remove this lab's app, ECR, IAM bootstrap, EKS, and VPC.
# S3 buckets and objects are deliberately retained. Verify account and ownership first.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_lab
assert_lab_cluster
require eksctl
apps="$(kubectl get storageapps.platform.example.com --all-namespaces -o json)"
[[ "$(jq '[.items[]|select(.metadata.namespace!="idp-lab" or .metadata.name!="demo")]|length' <<<"${apps}")" == 0 ]] || fail 'Unexpected StorageApps exist; refusing cluster cleanup.'
kubectl -n idp-lab delete storageapp/demo --ignore-not-found --wait=true --timeout=600s
wait_demo_resources_deleted
# Keeping providers running until every MR disappears lets their finalizers finish.
for resource in buckets.s3.aws.m.upbound.io bucketpublicaccessblocks.s3.aws.m.upbound.io \
  bucketserversideencryptionconfigurations.s3.aws.m.upbound.io roles.iam.aws.m.upbound.io \
  rolepolicies.iam.aws.m.upbound.io podidentityassociations.eks.aws.m.upbound.io; do
  [[ "$(kubectl get "${resource}" --all-namespaces -o json | jq '.items|length')" == 0 ]] || fail "Remaining ${resource}; refusing to remove controllers."
done
aws s3api list-buckets --output json | jq --arg prefix "idplab-${AWS_ACCOUNT_ID}-${LAB_ID}-" \
  '[.Buckets[]|select(.Name|startswith($prefix))|{name:.Name,created:.CreationDate}]' > "${REPO_DIR}/.local/retained-buckets.json"
stack_tags="$(aws cloudformation describe-stacks --stack-name "${BOOTSTRAP_STACK}" --query 'Stacks[0].Tags' --output json)"
[[ "$(jq -r '.[]|select(.Key=="LabId")|.Value' <<<"${stack_tags}")" == "${LAB_ID}" ]] || fail 'Bootstrap ownership mismatch.'
aws cloudformation delete-stack --stack-name "${BOOTSTRAP_STACK}"
aws cloudformation wait stack-delete-complete --stack-name "${BOOTSTRAP_STACK}"
eksctl delete cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" --wait
printf 'Deleted EKS and bootstrap. Retained S3 inventory: .local/retained-buckets.json\n'
