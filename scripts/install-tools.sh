#!/usr/bin/env bash
# Usage: scripts/install-tools.sh. Install pinned Helm, kind, and eksctl into .local/bin.
# Downloads are verified against upstream SHA256 files. Existing system tools are untouched.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require curl tar shasum
os="$(uname -s)"
case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; x86_64) arch=amd64 ;; *) fail 'Unsupported architecture.' ;; esac
case "${os}" in Darwin) platform=darwin ;; Linux) platform=linux ;; *) fail 'Use macOS or Linux.' ;; esac
mkdir -p "${REPO_DIR}/.local/bin"
temp_dir="$(mktemp -d)"
# Usage: remove_downloads. Remove only this script's mktemp directory on exit.
remove_downloads() { rm -rf "${temp_dir}"; }
trap remove_downloads EXIT
cd "${temp_dir}"
helm_archive="helm-v${HELM_VERSION}-${platform}-${arch}.tar.gz"
curl -fsSLO "https://get.helm.sh/${helm_archive}"
curl -fsSLO "https://get.helm.sh/${helm_archive}.sha256sum"
shasum -a 256 -c "${helm_archive}.sha256sum"
tar -xzf "${helm_archive}"
cp "${platform}-${arch}/helm" "${REPO_DIR}/.local/bin/helm"
kind_file="kind-${platform}-${arch}"
curl -fsSLO "https://github.com/kubernetes-sigs/kind/releases/download/v${KIND_VERSION}/${kind_file}"
curl -fsSLO "https://github.com/kubernetes-sigs/kind/releases/download/v${KIND_VERSION}/${kind_file}.sha256sum"
shasum -a 256 -c "${kind_file}.sha256sum"
cp "${kind_file}" "${REPO_DIR}/.local/bin/kind"
eksctl_archive="eksctl_${os}_${arch}.tar.gz"
curl -fsSLO "https://github.com/eksctl-io/eksctl/releases/download/v${EKSCTL_VERSION}/${eksctl_archive}"
curl -fsSLO "https://github.com/eksctl-io/eksctl/releases/download/v${EKSCTL_VERSION}/eksctl_checksums.txt"
# Avoid depending on rg in a bootstrap script; the filename has only safe characters.
awk -v archive="${eksctl_archive}" '$2==archive {print}' eksctl_checksums.txt > selected.sha256
[[ -s selected.sha256 ]] || fail 'No checksum for this platform.'
shasum -a 256 -c selected.sha256
tar -xzf "${eksctl_archive}"
cp eksctl "${REPO_DIR}/.local/bin/eksctl"
chmod +x "${REPO_DIR}/.local/bin/"{helm,kind,eksctl}
printf 'Add to PATH: %s/.local/bin\n' "${REPO_DIR}"
