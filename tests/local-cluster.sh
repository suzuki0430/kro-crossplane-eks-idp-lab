#!/usr/bin/env bash
# Usage: tests/local-cluster.sh. Create an isolated kind cluster, test KRO, and delete it.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/common.sh"
require kind helm kubectl docker shasum
readonly TEST_CLUSTER=kro-idp-ci
mkdir -p "${REPO_DIR}/.local"
export KUBECONFIG="${REPO_DIR}/.local/kind-ci.kubeconfig"
# Usage: remove_test_cluster. Preserve diagnostics on failure, then remove our local cluster.
remove_test_cluster() {
  local result=$?
  if [[ "${result}" != 0 ]]; then
    kubectl get rgd storage-app -o yaml > "${REPO_DIR}/.local/graph-failure.yaml" 2>/dev/null || true
    kubectl logs -n kro-system deployment/kro --tail=100 > "${REPO_DIR}/.local/kro-failure.log" 2>/dev/null || true
  fi
  kind delete cluster --name "${TEST_CLUSTER}"
}
kind create cluster --name "${TEST_CLUSTER}" --image "${KIND_NODE_IMAGE}" --kubeconfig "${KUBECONFIG}" --wait 120s
trap remove_test_cluster EXIT
helm pull oci://registry.k8s.io/kro/charts/kro --version "${KRO_VERSION}" --destination "${REPO_DIR}/.local"
(cd "${REPO_DIR}/.local" && awk '/kro-/ {print}' "${REPO_DIR}/charts.sha256" | shasum -a 256 -c -)
helm upgrade --install kro "${REPO_DIR}/.local/kro-${KRO_VERSION}.tgz" -n kro-system --create-namespace \
  -f "${REPO_DIR}/platform/kro-values.yaml" --wait --timeout 180s
(cd "${REPO_DIR}" && shasum -a 256 -c tests/crds.sha256)
kubectl apply --server-side -f "${REPO_DIR}/tests/crds/"
bash "${REPO_DIR}/tests/graph.sh"
