#!/usr/bin/env bash
# Terraform external data source: pull an OCI Helm chart from dhi.io into a local directory.
# Why: the DHI Karpenter chart tag (appVersion) differs from its Chart.yaml version (tag 1.15.1 has
# version 1.14.1), and the helm provider rejects a release whose chart version differs from the
# configured one. A local chart path has no such check.
# stdin: JSON {"chart":"karpenter-chart","version":"1.15.1","dest":"<dir>","username":"..","password":".."}
# stdout: JSON {"path":"<dir>/<chart>"}
set -euo pipefail
for tool in helm jq; do
  command -v "$tool" >/dev/null || { echo "pull-dhi-chart.sh: '$tool' is required in PATH to pull the DHI Karpenter chart (aws/karpenter.tf), but was not found." >&2; exit 1; }
done
in=$(cat)
chart=$(jq -r .chart <<<"$in"); version=$(jq -r .version <<<"$in"); dest=$(jq -r .dest <<<"$in")
user=$(jq -r .username <<<"$in"); pass=$(jq -r .password <<<"$in")
out="$dest/$chart-$version"
if [ ! -f "$out/$chart/Chart.yaml" ]; then
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  export HELM_REGISTRY_CONFIG="$tmp/registry.json" HELM_CACHE_HOME="$tmp/cache" HELM_CONFIG_HOME="$tmp/config" HELM_DATA_HOME="$tmp/data"
  printf '%s' "$pass" | helm registry login dhi.io --username "$user" --password-stdin >&2
  mkdir -p "$out"
  helm pull "oci://dhi.io/$chart" --version "$version" --untar --untardir "$out" >&2
fi
jq -n --arg p "$out/$chart" '{path:$p}'
