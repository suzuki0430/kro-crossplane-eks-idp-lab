#!/usr/bin/env bash
# Usage: scripts/capture-evidence.sh ready|failure|recovered|retained|reconnected
# Record real CLI observations for article screenshots. Raw logs remain in .local/.
# Account IDs are replaced before saving; review the output before publishing it.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_lab
assert_lab_cluster
stage="${1:?An evidence stage is required}"
case "${stage}" in ready|failure|recovered|retained|reconnected) ;; *) fail 'Unknown evidence stage.' ;; esac
mkdir -p "${REPO_DIR}/.local/evidence"
bucket="idplab-${AWS_ACCOUNT_ID}-${LAB_ID}-demo"
{
  printf 'EKS IDP LAB | %s | %s | %s\n' "${COMPOSER}" "${stage}" "$(date -u +%FT%TZ)"
  printf '\nStorageApp (kubectl get storageapps -n idp-lab, selected columns)\n'
  kubectl -n idp-lab get storageapps.platform.example.com -o 'custom-columns=NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,REPLICAS:.status.availableReplicas'
  printf '\n$ kubectl get deployment storage-demo -n idp-lab\n'
  kubectl -n idp-lab get deployment storage-demo --ignore-not-found
  printf '\nManaged resources (six kubectl get queries; type / Ready / Synced)\n'
  for resource in buckets.s3.aws.m.upbound.io bucketpublicaccessblocks.s3.aws.m.upbound.io \
    bucketserversideencryptionconfigurations.s3.aws.m.upbound.io roles.iam.aws.m.upbound.io \
    rolepolicies.iam.aws.m.upbound.io podidentityassociations.eks.aws.m.upbound.io; do
    kubectl -n idp-lab get "${resource}" -o json | jq -r '.items[] | [.kind, ([.status.conditions[]? | select(.type=="Ready") | .status][0] // "-"), ([.status.conditions[]? | select(.type=="Synced") | .status][0] // "-")] | @tsv'
  done
  case "${stage}" in
    ready)
      printf '\n$ sha256(probe.bin / HTTP response.bin)\n'
      (cd "${REPO_DIR}/.local" && shasum -a 256 probe.bin response.bin)
      cat "${REPO_DIR}/.local/verify.txt"
      ;;
    failure)
      printf '\n$ kubectl logs deployment/storage-demo --tail=3\n'
      kubectl -n idp-lab logs deployment/storage-demo --tail=3
      ;;
    recovered) cat "${REPO_DIR}/.local/experiment-failure.txt" ;;
    retained|reconnected)
      printf '\n$ aws s3api get-public-access-block / get-bucket-encryption\n'
      aws s3api get-public-access-block --bucket "${bucket}" --query PublicAccessBlockConfiguration --output json
      aws s3api get-bucket-encryption --bucket "${bucket}" --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault' --output json
      printf '\n$ sha256(original / retained / reconnected)\n'
      (cd "${REPO_DIR}/.local" && shasum -a 256 probe.bin retained.bin)
      if [[ "${stage}" == reconnected ]]; then
        (cd "${REPO_DIR}/.local" && shasum -a 256 reconnected.bin)
        cat "${REPO_DIR}/.local/experiment-retention.txt"
      else
        cat "${REPO_DIR}/.local/retained-before-reconnect.txt"
      fi
      ;;
  esac
} 2>&1 | sed "s/${AWS_ACCOUNT_ID}/ACCOUNT_ID/g" > "${REPO_DIR}/.local/evidence/${stage}.txt"
printf 'Recorded .local/evidence/%s.txt\n' "${stage}"
