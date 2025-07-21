#!/usr/bin/env sh
set -e

TINKEY_VERSION="1.11.0"
K9S_VERSION="v0.50.9"

# Install Java and vim
sudo apt-get update
sudo apt-get install -y openjdk-17-jre-headless vim

# Install Tinkey
sudo curl -fsSL -o /tmp/tinkey.tgz https://storage.googleapis.com/tinkey/tinkey-${TINKEY_VERSION}.tar.gz
sudo tar -xzf /tmp/tinkey.tgz -C /usr/local/bin tinkey tinkey_deploy.jar
sudo chmod +x /usr/local/bin/tinkey
sudo rm -f /tmp/tinkey.tgz


# Install k9s CLI (latest GitHub release)
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
sudo rm -rf /var/lib/apt/lists/*

