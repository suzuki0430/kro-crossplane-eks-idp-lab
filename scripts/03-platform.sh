#!/usr/bin/env bash
# Usage: scripts/03-platform.sh. Install the selected composer and six managed types.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_lab
assert_lab_cluster
require helm
helm pull oci://registry.k8s.io/kro/charts/kro --version "${KRO_VERSION}" --destination "${REPO_DIR}/.local"
helm pull crossplane --repo https://charts.crossplane.io/stable --version "${CROSSPLANE_VERSION}" --destination "${REPO_DIR}/.local"
(cd "${REPO_DIR}/.local" && shasum -a 256 -c "${REPO_DIR}/charts.sha256")
if [[ "${COMPOSER}" == kro ]]; then
  helm upgrade --install kro "${REPO_DIR}/.local/kro-${KRO_VERSION}.tgz" -n kro-system --create-namespace \
    -f "${REPO_DIR}/platform/kro-values.yaml" --wait --timeout 180s
  kubectl apply -f "${REPO_DIR}/platform/rbac.yaml"
else
  # The two implementations deliberately share one API; use a new lab per variant.
  if [[ -n "$(kubectl get crd storageapps.platform.example.com --ignore-not-found -o name)" ]]; then
    [[ -n "$(kubectl get xrd storageapps.platform.example.com --ignore-not-found -o name)" ]] || fail 'Use a fresh cluster for the Composition variant.'
  fi
fi
helm upgrade --install crossplane "${REPO_DIR}/.local/crossplane-${CROSSPLANE_VERSION}.tgz" -n crossplane-system --create-namespace \
  -f "${REPO_DIR}/platform/crossplane-values.yaml" --wait --timeout 180s
kubectl apply -f "${REPO_DIR}/platform/activation.yaml"

# Separate stable service accounts bind each provider to its own Pod Identity role.
for service in family s3 iam eks; do
  if [[ "${service}" == family ]]; then package=provider-family-aws; else package="provider-aws-${service}"; fi
  jq -n --arg name "provider-aws-${service}" '{
    apiVersion:"pkg.crossplane.io/v1beta1",kind:"DeploymentRuntimeConfig",metadata:{name:$name},
    spec:{serviceAccountTemplate:{metadata:{name:$name}},deploymentTemplate:{spec:{selector:{},template:{spec:{containers:[{
      name:"package-runtime",env:[{name:"AWS_EC2_METADATA_DISABLED",value:"true"}],
      resources:{requests:{cpu:"100m",memory:"256Mi"},limits:{cpu:"1",memory:"1Gi"}}
    }]}}}}}
  }' | kubectl apply -f -
  jq -n --arg name "${package}" --arg runtime "provider-aws-${service}" --arg version "${AWS_PROVIDER_VERSION}" '{
    apiVersion:"pkg.crossplane.io/v1",kind:"Provider",metadata:{name:$name},
    spec:{package:("xpkg.crossplane.io/crossplane-contrib/"+$name+":v"+$version),
      runtimeConfigRef:{name:$runtime},revisionActivationPolicy:"Automatic",revisionHistoryLimit:1}
  }' | kubectl apply -f -
  kubectl wait --for=condition=Healthy "provider/${package}" --timeout=600s
done
for crd in buckets.s3.aws.m.upbound.io bucketpublicaccessblocks.s3.aws.m.upbound.io \
  bucketserversideencryptionconfigurations.s3.aws.m.upbound.io roles.iam.aws.m.upbound.io \
  rolepolicies.iam.aws.m.upbound.io podidentityassociations.eks.aws.m.upbound.io providerconfigs.aws.m.upbound.io; do
  kubectl wait --for=condition=Established "crd/${crd}" --timeout=180s
done
if [[ "${COMPOSER}" == kro ]]; then
  kubectl apply -f "${REPO_DIR}/platform/storage-app.yaml"
  kubectl wait --for=condition=Ready rgd/storage-app --timeout=120s
fi

kubectl create namespace idp-lab --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace idp-lab pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version="v${EKS_VERSION}" --overwrite
kubectl -n idp-lab create configmap storage-platform \
  --from-literal="labId=${LAB_ID}" --from-literal="region=${AWS_REGION}" \
  --from-literal="clusterName=${CLUSTER_NAME}" \
  --from-literal="clusterArn=arn:aws:eks:${AWS_REGION}:${AWS_ACCOUNT_ID}:cluster/${CLUSTER_NAME}" \
  --from-literal="bucketPrefix=idplab-${AWS_ACCOUNT_ID}-${LAB_ID}-" \
  --from-literal="boundaryArn=$(bootstrap_output BoundaryArn)" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${REPO_DIR}/platform/tenant.yaml"
if [[ "${COMPOSER}" == crossplane ]]; then
  kubectl apply -f "${REPO_DIR}/platform/composition/function.yaml"
  kubectl wait --for=condition=Healthy function/function-go-templating --timeout=300s
  kubectl apply -f "${REPO_DIR}/platform/composition/xrd.yaml"
  kubectl wait --for=condition=Established xrd/storageapps.platform.example.com --timeout=120s
  kubectl apply -f "${REPO_DIR}/platform/composition/composition.yaml"
fi
