#!/usr/bin/env sh
set -e

TINKEY_VERSION="$(curl -sS https://api.github.com/repos/tink-crypto/tink-tinkey/releases/latest | jq -r '.tag_name' | sed 's/^v//')"
K9S_VERSION="$(curl -sS https://api.github.com/repos/derailed/k9s/releases/latest | jq -r '.tag_name')"
KUBELOGIN_VERSION="$(curl -sS https://api.github.com/repos/Azure/kubelogin/releases/latest | jq -r '.tag_name' | sed 's/^v//')"
K3D_VERSION="$(curl -sS https://api.github.com/repos/k3d-io/k3d/releases/latest | jq -r '.tag_name')"

# Install Java and vim
sudo apt-get update
sudo apt-get install -y openjdk-21-jre-headless vim jq unzip

# Install Tinkey
sudo curl -fsSL -o /tmp/tinkey.tgz https://storage.googleapis.com/tinkey/tinkey-${TINKEY_VERSION}.tar.gz
sudo tar -xzf /tmp/tinkey.tgz -C /usr/local/bin tinkey tinkey_deploy.jar
sudo chmod +x /usr/local/bin/tinkey
sudo rm -f /tmp/tinkey.tgz

# Install k9s CLI
sudo apt-get update
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

# Install kubelogin for AKS exec auth
ARCH=$(dpkg --print-architecture)
case "$ARCH" in
  amd64) PKG_ARCH="amd64" ;;
  arm64) PKG_ARCH="arm64" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac
curl -fsSL -o /tmp/kubelogin.zip "https://github.com/Azure/kubelogin/releases/download/v${KUBELOGIN_VERSION}/kubelogin-linux-${PKG_ARCH}.zip"
sudo unzip -q /tmp/kubelogin.zip -d /tmp
sudo install -m 0755 /tmp/bin/linux_${PKG_ARCH}/kubelogin /usr/local/bin/kubelogin
sudo rm -rf /tmp/kubelogin.zip /tmp/bin

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
