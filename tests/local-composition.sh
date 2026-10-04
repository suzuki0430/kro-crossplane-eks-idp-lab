#!/usr/bin/env bash
# Usage: tests/local-composition.sh. Test real Crossplane and Function with mocked AWS status.
# This disposable kind cluster contains no KRO and never contacts AWS.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/common.sh"
require kind helm kubectl docker shasum
readonly TEST_CLUSTER=crossplane-idp-ci
mkdir -p "${REPO_DIR}/.local"
export KUBECONFIG="${REPO_DIR}/.local/composition-ci.kubeconfig"
# Usage: remove_test_cluster. Keep controller diagnostics before removing this test cluster.
remove_test_cluster() {
  local result=$?
  if [[ "${result}" != 0 ]]; then
    kubectl get storageapps -A -o yaml > "${REPO_DIR}/.local/composition-failure.yaml" 2>/dev/null || true
    kubectl logs -n crossplane-system deployment/crossplane --tail=100 > "${REPO_DIR}/.local/crossplane-failure.log" 2>/dev/null || true
  fi
  if [[ "${KEEP_TEST_CLUSTER:-false}" != true ]]; then
    kind delete cluster --name "${TEST_CLUSTER}"
  fi
}
kind create cluster --name "${TEST_CLUSTER}" --image "${KIND_NODE_IMAGE}" --kubeconfig "${KUBECONFIG}" --wait 120s
trap remove_test_cluster EXIT
helm pull crossplane --repo https://charts.crossplane.io/stable --version "${CROSSPLANE_VERSION}" --destination "${REPO_DIR}/.local"
(cd "${REPO_DIR}/.local" && awk '/crossplane-/ {print}' "${REPO_DIR}/charts.sha256" | shasum -a 256 -c -)
helm upgrade --install crossplane "${REPO_DIR}/.local/crossplane-${CROSSPLANE_VERSION}.tgz" -n crossplane-system --create-namespace \
  -f "${REPO_DIR}/platform/crossplane-values.yaml" --wait --timeout 180s
(cd "${REPO_DIR}" && shasum -a 256 -c tests/crds.sha256)
kubectl apply --server-side -f "${REPO_DIR}/tests/crds/"
kubectl create namespace idp-lab
kubectl apply -f "${REPO_DIR}/platform/composition/rbac.yaml"
kubectl apply -f "${REPO_DIR}/platform/composition/function.yaml"
kubectl wait --for=condition=Healthy function/function-go-templating --timeout=300s
kubectl apply -f "${REPO_DIR}/platform/composition/xrd.yaml"
kubectl wait --for=condition=Established xrd/storageapps.platform.example.com --timeout=120s
kubectl apply -f "${REPO_DIR}/platform/composition/composition.yaml"
bash "${REPO_DIR}/tests/composition.sh"
