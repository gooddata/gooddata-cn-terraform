#!/usr/bin/env sh
set -eu

TINKEY_VERSION="1.11.0"
K9S_VERSION="$(curl -sS https://api.github.com/repos/derailed/k9s/releases/latest | jq -r '.tag_name')"
GCLOUD_VERSION="474.0.0"

# Detect architecture once
ARCH=$(dpkg --print-architecture)
case "$ARCH" in
  amd64) PKG_ARCH="amd64" ;;
  arm64) PKG_ARCH="arm64" ;;
  armhf) PKG_ARCH="armhf" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

# Base packages in a single transaction
sudo apt-get update -qq
sudo apt-get install -y -qq --no-install-recommends \
  ca-certificates curl gnupg jq apt-transport-https \
  openjdk-17-jre-headless vim

# Install Tinkey
tmp_tgz="$(mktemp)" || true
sudo curl -fsSL -o "$tmp_tgz" "https://storage.googleapis.com/tinkey/tinkey-${TINKEY_VERSION}.tar.gz"
sudo tar -xzf "$tmp_tgz" -C /usr/local/bin tinkey tinkey_deploy.jar
sudo chmod +x /usr/local/bin/tinkey
sudo rm -f "$tmp_tgz"

# Install k9s
tmp_deb="$(mktemp)" || true
curl -fsSL -o "$tmp_deb" "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_linux_${PKG_ARCH}.deb"
sudo dpkg -i "$tmp_deb" || sudo apt-get -y -qq -f install
sudo rm -f "$tmp_deb"

# Install Google Cloud CLI and GKE auth plugin
echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list >/dev/null
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
sudo apt-get update -qq
sudo apt-get install -y -qq google-cloud-cli google-cloud-sdk-gke-gcloud-auth-plugin

# Prefer using the auth plugin env var for modern kubectl
echo "export USE_GKE_GCLOUD_AUTH_PLUGIN=True" | sudo tee /etc/profile.d/gke-auth.sh >/dev/null
