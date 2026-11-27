#!/usr/bin/env bash
set -euo pipefail

# Tool versions are pinned and kept current by Renovate (see renovate.json).
# renovate: datasource=github-releases depName=tink-crypto/tink-tinkey extractVersion=^v(?<version>.+)$
TINKEY_VERSION="1.14.0"
# renovate: datasource=github-releases depName=derailed/k9s
K9S_VERSION="v0.51.0"
# renovate: datasource=github-releases depName=Azure/kubelogin extractVersion=^v(?<version>.+)$
KUBELOGIN_VERSION="0.2.22"
# renovate: datasource=github-releases depName=k3d-io/k3d
K3D_VERSION="v5.9.0"
# renovate: datasource=github-releases depName=stackitcloud/stackit-cli extractVersion=^v(?<version>.+)$
STACKIT_CLI_VERSION="0.77.2"

# Install Java and vim
sudo apt-get update
sudo apt-get install -y openjdk-21-jre-headless vim jq unzip

# Install Tinkey
sudo curl -fsSL -o /tmp/tinkey.tgz https://storage.googleapis.com/tinkey/tinkey-${TINKEY_VERSION}.tar.gz
sudo tar -xzf /tmp/tinkey.tgz -C /usr/local/bin tinkey tinkey_deploy.jar
sudo chmod +x /usr/local/bin/tinkey
sudo rm -f /tmp/tinkey.tgz

# Install k9s CLI
ARCH=$(dpkg --print-architecture)
case "$ARCH" in
  amd64) PKG_ARCH="amd64" ;;
  arm64) PKG_ARCH="arm64" ;;
  armhf) PKG_ARCH="armhf" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac
curl -fsSL -o /tmp/k9s.deb "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_linux_${PKG_ARCH}.deb"
sudo dpkg -i /tmp/k9s.deb || sudo apt-get -y -f install
sudo rm /tmp/k9s.deb
command -v k9s >/dev/null || { echo "ERROR: k9s install failed" >&2; exit 1; }

# Install kubelogin for AKS exec auth
ARCH=$(dpkg --print-architecture)
case "$ARCH" in
  amd64) PKG_ARCH="amd64" ;;
  arm64) PKG_ARCH="arm64" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac
curl -fsSL -o /tmp/kubelogin.zip "https://github.com/Azure/kubelogin/releases/download/v${KUBELOGIN_VERSION}/kubelogin-linux-${PKG_ARCH}.zip"
sudo unzip -q /tmp/kubelogin.zip -d /tmp
sudo install -m 0755 "/tmp/bin/linux_${PKG_ARCH}/kubelogin" /usr/local/bin/kubelogin
sudo rm -rf /tmp/kubelogin.zip /tmp/bin

# Install the STACKIT CLI. Terraform authenticates from a service account key, so
# this is for listing machine types and PostgreSQL Flex flavors.
ARCH=$(dpkg --print-architecture)
case "$ARCH" in
  amd64) PKG_ARCH="amd64" ;;
  arm64) PKG_ARCH="arm64" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac
# mktemp, not a fixed /tmp path: dpkg runs under sudo, so a pre-created file or
# symlink there would hand a local process control of what gets installed.
STACKIT_DEB="$(mktemp --suffix=.deb)"
trap 'rm -f -- "${STACKIT_DEB}"' EXIT
curl -fsSL -o "${STACKIT_DEB}" "https://github.com/stackitcloud/stackit-cli/releases/download/v${STACKIT_CLI_VERSION}/stackit_${STACKIT_CLI_VERSION}_linux_${PKG_ARCH}.deb"
sudo dpkg -i "${STACKIT_DEB}" || sudo apt-get -y -f install
command -v stackit >/dev/null || { echo "ERROR: stackit CLI install failed" >&2; exit 1; }

# Install k3d (for local deployments)
ARCH=$(uname -m)
case "$ARCH" in
  armv5*) ARCH="armv5" ;;
  armv6*) ARCH="armv6" ;;
  armv7*) ARCH="arm" ;;
  aarch64|arm64) ARCH="arm64" ;;
  x86) ARCH="386" ;;
  x86_64) ARCH="amd64" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac
OS=$(uname | tr '[:upper:]' '[:lower:]')
sudo curl -fsSL -o /usr/local/bin/k3d \
  "https://github.com/k3d-io/k3d/releases/download/${K3D_VERSION}/k3d-${OS}-${ARCH}"
sudo chmod +x /usr/local/bin/k3d

# Shared provider cache: TF_PLUGIN_CACHE_DIR (devcontainer.json) makes providers
# download once and symlink into each working dir; prune it manually as it grows.
if [ -n "${TF_PLUGIN_CACHE_DIR:-}" ]; then
  mkdir -p "${TF_PLUGIN_CACHE_DIR}"
fi
