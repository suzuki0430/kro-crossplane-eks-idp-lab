#!/usr/bin/env bash
# Usage: scripts/01-cluster.sh. Create a tagged EKS lab and record resolved add-on pins.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_lab
require eksctl
: "${ADMIN_CIDR:?Set your public IPv4/32 in ADMIN_CIDR}"
[[ "${ADMIN_CIDR}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/32$ ]] || fail 'ADMIN_CIDR must be one public IPv4 address with /32.'
[[ "$(eksctl version)" == "${EKSCTL_VERSION}" ]] || fail "Use eksctl ${EKSCTL_VERSION}."

# Keep existing pins and resolve only missing add-ons after a script update.
addons='[]'
if [[ -f "${REPO_DIR}/.local/addons.json" ]]; then
  addons="$(cat "${REPO_DIR}/.local/addons.json")"
fi
for addon in vpc-cni kube-proxy coredns eks-pod-identity-agent metrics-server; do
  if ! jq -e --arg name "${addon}" 'any(.[]; .name==$name)' <<<"${addons}" >/dev/null; then
    version="$(aws eks describe-addon-versions --addon-name "${addon}" --kubernetes-version "${EKS_VERSION}" --output json |
      jq -er '[.addons[0].addonVersions[] | select(any(.compatibilities[]; .defaultVersion==true))][0].addonVersion')"
    [[ "${version}" != null && -n "${version}" ]] || fail "No compatible ${addon}."
    addons="$(jq --arg name "${addon}" --arg version "${version}" '. + [{name:$name,version:$version}]' <<<"${addons}")"
  fi
done
printf '%s\n' "${addons}" > "${REPO_DIR}/.local/addons.json"
jq -n --arg name "${CLUSTER_NAME}" --arg region "${AWS_REGION}" --arg version "${EKS_VERSION}" \
  --arg lab "${LAB_ID}" --arg cidr "${ADMIN_CIDR}" --slurpfile addons "${REPO_DIR}/.local/addons.json" '{
  apiVersion:"eksctl.io/v1alpha5",kind:"ClusterConfig",
  autoModeConfig:{enabled:false},
  metadata:{name:$name,region:$region,version:$version,tags:{ManagedBy:"kro-crossplane-idp-lab",LabId:$lab}},
  vpc:{cidr:"10.80.0.0/16",nat:{gateway:"Disable"},clusterEndpoints:{publicAccess:true,privateAccess:true},publicAccessCIDRs:[$cidr]},
  upgradePolicy:{supportType:"STANDARD"},
  managedNodeGroups:[{name:"lab",instanceType:"m7i.xlarge",desiredCapacity:1,minSize:1,maxSize:1,
    amiFamily:"AmazonLinux2023",privateNetworking:false,volumeSize:30,volumeType:"gp3",volumeEncrypted:true,
    disableIMDSv1:true,disablePodIMDS:true,ssh:{allow:false},tags:{ManagedBy:"kro-crossplane-idp-lab",LabId:$lab}}],
  addons:$addons[0]
}' > "${REPO_DIR}/.local/cluster.json"
# dry-run validates the exact eksctl schema before any paid resources are created.
eksctl create cluster -f "${REPO_DIR}/.local/cluster.json" --dry-run >/dev/null
eksctl create cluster -f "${REPO_DIR}/.local/cluster.json" --kubeconfig "${KUBECONFIG}"
assert_lab_cluster
kubectl wait --for=condition=Ready nodes --all --timeout=300s
aws eks describe-cluster --name "${CLUSTER_NAME}" --query 'cluster.{version:version,platformVersion:platformVersion,status:status}' --output json > "${REPO_DIR}/.local/eks-version.json"
