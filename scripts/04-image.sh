#!/usr/bin/env bash
# Usage: scripts/04-image.sh. Publish the demo to this lab's ECR; save its immutable digest.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_lab
assert_lab_cluster
require docker
repository="$(bootstrap_output RepositoryUri)"
[[ "${repository}" == "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/idplab-${LAB_ID}/storage-api" ]] || fail 'Unexpected ECR output.'
tag="build-$(date -u +%Y%m%d%H%M%S)"
aws ecr get-login-password | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
docker build --platform linux/amd64 --tag "${repository}:${tag}" "${REPO_DIR}/app"
docker push "${repository}:${tag}"
digest="$(aws ecr describe-images --repository-name "idplab-${LAB_ID}/storage-api" --image-ids "imageTag=${tag}" --query 'imageDetails[0].imageDigest' --output text)"
[[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || fail 'Missing image digest.'
printf '%s@%s\n' "${repository}" "${digest}" > "${REPO_DIR}/.local/image.txt"
