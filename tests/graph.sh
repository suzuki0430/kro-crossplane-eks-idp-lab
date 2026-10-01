#!/usr/bin/env bash
# Usage: KUBECONFIG=/path/to/disposable-kind tests/graph.sh
# Tests real KRO/CRD reconciliation with simulated AWS status; never contacts AWS.
# Requires KRO and tests/crds installed. Only a kind-* context is accepted.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/common.sh"
require kubectl jq
[[ "$(kubectl config current-context)" == kind-* ]] || fail 'Graph tests require a disposable kind context.'
readonly TEST_NAMESPACE=graph-test
kubectl apply -f "${REPO_DIR}/platform/rbac.yaml" -f "${REPO_DIR}/platform/storage-app.yaml"
kubectl wait --for=condition=Ready rgd/storage-app --timeout=120s
kubectl create namespace "${TEST_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "${TEST_NAMESPACE}" create configmap storage-platform \
  --from-literal=labId=testing1 --from-literal=region=ap-northeast-1 --from-literal=clusterName=idplab-testing1 \
  --from-literal=clusterArn=arn:aws:eks:ap-northeast-1:123456789012:cluster/idplab-testing1 \
  --from-literal=bucketPrefix=idplab-123456789012-testing1- \
  --from-literal=boundaryArn=arn:aws:iam::123456789012:policy/idplab-testing1-workload-boundary \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "${TEST_NAMESPACE}" apply -f - <<'YAML'
apiVersion: platform.example.com/v1alpha1
kind: StorageApp
metadata:
  name: demo
spec:
  storageId: demo
  image: example.invalid/idp-test:1
YAML

# Usage: exists <resource/name>. Wait for KRO to create one expected child.
exists() { kubectl -n "${TEST_NAMESPACE}" wait --for=create "${1}" --timeout=90s >/dev/null; }
# Usage: absent <resource/name>. Assert dependencies have not been created prematurely.
absent() {
  [[ -z "$(kubectl -n "${TEST_NAMESPACE}" get "${1}" --ignore-not-found -o name)" ]] || fail "Premature resource: ${1}"
}
# Usage: ready <resource/name> [atProvider JSON]. Simulate only the cloud controller status.
ready() {
  local resource="${1}" at_provider="${2-}" patch
  [[ -n "${at_provider}" ]] || at_provider='{}'
  exists "${resource}"
  patch="$(jq -n --argjson at "${at_provider}" '{status:{atProvider:$at,conditions:[
    {type:"Ready",status:"True",reason:"Available",lastTransitionTime:"2026-10-01T00:00:00Z"},
    {type:"Synced",status:"True",reason:"ReconcileSuccess",lastTransitionTime:"2026-10-01T00:00:00Z"}]}}')"
  kubectl -n "${TEST_NAMESPACE}" patch "${resource}" --subresource=status --type=merge -p "${patch}" >/dev/null
}

exists bucket.s3.aws.m.upbound.io/storage-demo
exists role.iam.aws.m.upbound.io/storage-demo
absent rolepolicy.iam.aws.m.upbound.io/storage-demo
absent deployment/storage-demo
kubectl -n "${TEST_NAMESPACE}" patch bucket.s3.aws.m.upbound.io/storage-demo --subresource=status --type=merge -p \
  '{"status":{"conditions":[{"type":"Synced","status":"False","reason":"ReconcileError","message":"simulated AccessDenied","lastTransitionTime":"2026-10-01T00:00:00Z"}]}}' >/dev/null
kubectl -n "${TEST_NAMESPACE}" wait --for=jsonpath='{.status.storageMessage}'='simulated AccessDenied' storageapp/demo --timeout=60s
absent deployment/storage-demo
ready bucket.s3.aws.m.upbound.io/storage-demo
ready role.iam.aws.m.upbound.io/storage-demo '{"arn":"arn:aws:iam::123456789012:role/idplab/testing1/workloads/idplab-testing1-demo"}'
ready bucketpublicaccessblock.s3.aws.m.upbound.io/storage-demo
ready bucketserversideencryptionconfiguration.s3.aws.m.upbound.io/storage-demo
absent podidentityassociation.eks.aws.m.upbound.io/storage-demo
ready rolepolicy.iam.aws.m.upbound.io/storage-demo
absent deployment/storage-demo
ready podidentityassociation.eks.aws.m.upbound.io/storage-demo '{"associationId":"a-test"}'
exists deployment/storage-demo

# Validate effective manifests, not just the authoring YAML.
kubectl -n "${TEST_NAMESPACE}" get rolepolicy.iam.aws.m.upbound.io/storage-demo -o json |
  jq -e '.spec.forProvider.policy|fromjson|.Statement[0].Resource|all(contains("idplab-123456789012-testing1-demo/"))' >/dev/null
kubectl -n "${TEST_NAMESPACE}" get role.iam.aws.m.upbound.io/storage-demo -o json |
  jq -e '.spec.forProvider.assumeRolePolicy|fromjson|.Statement[0].Condition.StringEquals["aws:RequestTag/kubernetes-service-account"]=="storage-demo"' >/dev/null
for resource in bucket.s3.aws.m.upbound.io bucketpublicaccessblock.s3.aws.m.upbound.io bucketserversideencryptionconfiguration.s3.aws.m.upbound.io; do
  kubectl -n "${TEST_NAMESPACE}" get "${resource}/storage-demo" -o json |
    jq -e '.spec.managementPolicies | (index("Delete")==null and index("*")==null)' >/dev/null
done
if kubectl -n "${TEST_NAMESPACE}" patch storageapp/demo --type=merge -p '{"spec":{"storageId":"changed"}}' 2>/dev/null; then
  fail 'Immutable storage identity was accepted.'
fi
if kubectl -n "${TEST_NAMESPACE}" patch storageapp/demo --type=merge -p '{"spec":{"replicas":0}}' 2>/dev/null; then
  fail 'Invalid replica count was accepted.'
fi
kubectl -n "${TEST_NAMESPACE}" patch storageapp/demo --type=merge -p '{"spec":{"replicas":2}}' >/dev/null
kubectl -n "${TEST_NAMESPACE}" wait --for=jsonpath='{.spec.replicas}'=2 deployment/storage-demo --timeout=60s

# A finalizer on a dependent must hold its IAM role until that dependent disappears.
kubectl -n "${TEST_NAMESPACE}" patch podidentityassociation.eks.aws.m.upbound.io/storage-demo --type=merge \
  -p '{"metadata":{"finalizers":["lab.example.com/test-hold"]}}' >/dev/null
kubectl -n "${TEST_NAMESPACE}" delete storageapp/demo --wait=false >/dev/null
kubectl -n "${TEST_NAMESPACE}" wait --for=delete deployment/storage-demo --timeout=90s
kubectl -n "${TEST_NAMESPACE}" get role.iam.aws.m.upbound.io/storage-demo >/dev/null
kubectl -n "${TEST_NAMESPACE}" patch podidentityassociation.eks.aws.m.upbound.io/storage-demo --type=merge \
  -p '{"metadata":{"finalizers":[]}}' >/dev/null
kubectl -n "${TEST_NAMESPACE}" wait --for=delete storageapp/demo --timeout=90s
absent bucket.s3.aws.m.upbound.io/storage-demo
kubectl delete namespace "${TEST_NAMESPACE}" --wait=true >/dev/null
printf 'PASS: graph dependencies, error propagation, constraints, update, and ordered deletion.\n'
