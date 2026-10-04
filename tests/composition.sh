#!/usr/bin/env bash
# Usage: KUBECONFIG=/path/to/disposable-kind tests/composition.sh
# Tests real Crossplane/Function reconciliation with simulated AWS status; never contacts AWS.
# Requires the Composition variant and tests/crds installed. Only a kind-* context is accepted.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/common.sh"
require kubectl jq
[[ "$(kubectl config current-context)" == kind-* ]] || fail 'Composition tests require a disposable kind context.'
readonly TEST_NAMESPACE=idp-lab
# Realtime watches need read access; mutations must stay inside the lab namespace.
controller=system:serviceaccount:crossplane-system:crossplane
[[ "$(kubectl auth can-i watch deployments --all-namespaces --as="${controller}")" == yes ]] || fail 'Controller cannot observe deployments.'
if kubectl auth can-i create deployments -n default --as="${controller}" >/dev/null; then
  fail 'Controller can create deployments outside idp-lab.'
fi
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

# Usage: exists <resource/name>. Wait for Crossplane to create one expected child.
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
kubectl -n "${TEST_NAMESPACE}" wait --for=condition=Ready=false storageapp/demo --timeout=90s
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

# A temporary upstream failure must not remove previously created dependents.
deployment_uid="$(kubectl -n "${TEST_NAMESPACE}" get deployment/storage-demo -o jsonpath='{.metadata.uid}')"
kubectl -n "${TEST_NAMESPACE}" patch bucket.s3.aws.m.upbound.io/storage-demo --subresource=status --type=merge -p \
  '{"status":{"conditions":[{"type":"Ready","status":"True","reason":"Available","lastTransitionTime":"2026-10-04T00:00:00Z"},{"type":"Synced","status":"False","reason":"ReconcileError","message":"upstream-regression","lastTransitionTime":"2026-10-04T00:00:00Z"}]}}' >/dev/null
kubectl -n "${TEST_NAMESPACE}" wait --for=jsonpath='{.status.storageMessage}'='upstream-regression' storageapp/demo --timeout=90s
[[ "$(kubectl -n "${TEST_NAMESPACE}" get deployment/storage-demo -o jsonpath='{.metadata.uid}')" == "${deployment_uid}" ]] || fail 'Upstream failure recreated the Deployment.'
kubectl -n "${TEST_NAMESPACE}" wait --for=condition=Ready=false storageapp/demo --timeout=60s

kubectl -n "${TEST_NAMESPACE}" delete storageapp/demo --wait=true --timeout=120s
wait_demo_resources_deleted
kubectl delete namespace "${TEST_NAMESPACE}" --wait=true >/dev/null
printf 'PASS: Composition dependencies, partial readiness, errors, constraints, updates, stable dependents, and cleanup.\n'
