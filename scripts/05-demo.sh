#!/usr/bin/env bash
# Usage: scripts/05-demo.sh. Submit the developer-facing API and wait for usable storage.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_lab
assert_lab_cluster
[[ -f "${REPO_DIR}/.local/image.txt" ]] || fail 'Run scripts/04-image.sh first.'
image="$(cat "${REPO_DIR}/.local/image.txt")"
jq -n --arg image "${image}" '{apiVersion:"platform.example.com/v1alpha1",kind:"StorageApp",
  metadata:{name:"demo",namespace:"idp-lab"},spec:{storageId:"demo",image:$image,replicas:1}}' \
  > "${REPO_DIR}/.local/demo.json"
kubectl apply --as=system:serviceaccount:idp-lab:developer-demo -f "${REPO_DIR}/.local/demo.json"
kubectl -n idp-lab wait --for=condition=Ready storageapp/demo --timeout=900s
kubectl -n idp-lab get storageapp/demo -o yaml > "${REPO_DIR}/.local/demo-ready.yaml"
