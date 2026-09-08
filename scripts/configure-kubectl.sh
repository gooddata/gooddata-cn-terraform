#!/usr/bin/env bash
set -euo pipefail

# Configure kubectl to connect to the Kubernetes cluster provisioned by Terraform.
# Run this script from the aws/, azure/, stackit/, or local/ directory after running `terraform apply`.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

CURRENT_DIR=$(basename "$(pwd)")

case "${CURRENT_DIR}" in
  aws)
    require_command aws "AWS CLI not found; install it to configure kubectl."
    require_command kubectl "kubectl not found; install it to interact with Kubernetes."
    require_tf_outputs

    EKS_CLUSTER_NAME=$(tf_output_value "eks_cluster_name")
    AWS_REGION=$(tf_output_value "aws_region")
    AWS_PROFILE=$(tf_output_value "aws_profile_name")

    if [[ -z "${EKS_CLUSTER_NAME}" || -z "${AWS_REGION}" ]]; then
      echo ">> ERROR: Missing required Terraform outputs (eks_cluster_name, aws_region)." >&2
      exit 1
    fi

    echo ">> Configuring kubectl for EKS cluster '${EKS_CLUSTER_NAME}' in region '${AWS_REGION}'..."
    aws eks update-kubeconfig \
      --name "${EKS_CLUSTER_NAME}" \
      --region "${AWS_REGION}" \
      ${AWS_PROFILE:+--profile "${AWS_PROFILE}"}

    echo ">> kubectl configured successfully."
    ;;

  azure)
    require_command az "Azure CLI not found; install it to configure kubectl."
    require_command kubectl "kubectl not found; install it to interact with Kubernetes."
    require_tf_outputs

    AKS_CLUSTER_NAME=$(tf_output_value "aks_cluster_name")
    RESOURCE_GROUP=$(tf_output_value "azure_resource_group_name")

    if [[ -z "${AKS_CLUSTER_NAME}" || -z "${RESOURCE_GROUP}" ]]; then
      echo ">> ERROR: Missing required Terraform outputs (aks_cluster_name, azure_resource_group_name)." >&2
      exit 1
    fi

    echo ">> Configuring kubectl for AKS cluster '${AKS_CLUSTER_NAME}' in resource group '${RESOURCE_GROUP}'..."
    az aks get-credentials \
      --resource-group "${RESOURCE_GROUP}" \
      --name "${AKS_CLUSTER_NAME}" \
      --overwrite-existing

    # Convert kubelogin to azurecli mode so kubectl reuses the `az login` token
    # instead of prompting for device-code auth on every command.
    if command -v kubelogin &>/dev/null; then
      kubelogin convert-kubeconfig -l azurecli
    fi

    echo ">> kubectl configured successfully."
    ;;

  stackit)
    require_command kubectl "kubectl not found; install it to interact with Kubernetes."
    require_tf_outputs

    SKE_CLUSTER_NAME=$(tf_output_value "ske_cluster_name")
    SKE_KUBECONFIG=$(tf_output_value "kubeconfig")

    if [[ -z "${SKE_CLUSTER_NAME}" || -z "${SKE_KUBECONFIG}" ]]; then
      echo ">> ERROR: Missing required Terraform outputs (ske_cluster_name, kubeconfig)." >&2
      exit 1
    fi

    # SKE hands out a ready-made kubeconfig rather than an exec-credential
    # plugin, so it is merged into the default kubeconfig here. It is short-lived:
    # rerun this script once it expires.
    SKE_KUBECONFIG_TMP=$(mktemp)
    SKE_MERGED_TMP=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '${SKE_KUBECONFIG_TMP}' '${SKE_MERGED_TMP}'" EXIT
    printf '%s' "${SKE_KUBECONFIG}" >"${SKE_KUBECONFIG_TMP}"

    echo ">> Merging kubeconfig for SKE cluster '${SKE_CLUSTER_NAME}'..."
    unset KUBECONFIG || true
    DEFAULT_KUBECONFIG="${HOME}/.kube/config"
    mkdir -p "$(dirname "${DEFAULT_KUBECONFIG}")"
    # The SKE file comes first so its entries win: the kubeconfig is short-lived,
    # and rerunning this must replace the expired one rather than be ignored.
    # --raw keeps credentials intact without --flatten, which would inline every
    # other cluster's key material into the user's config.
    KUBECONFIG="${SKE_KUBECONFIG_TMP}:${DEFAULT_KUBECONFIG}" \
      kubectl config view --raw >"${SKE_MERGED_TMP}"
    cp "${SKE_MERGED_TMP}" "${DEFAULT_KUBECONFIG}"
    chmod 600 "${DEFAULT_KUBECONFIG}"

    SKE_CONTEXT=$(KUBECONFIG="${SKE_KUBECONFIG_TMP}" kubectl config current-context)
    echo ">> Switching kubectl context to '${SKE_CONTEXT}'..."
    kubectl config use-context "${SKE_CONTEXT}"

    SKE_EXPIRES_AT=$(tf_output_value "kubeconfig_expires_at")
    if [[ -n "${SKE_EXPIRES_AT}" ]]; then
      echo ">> NOTE: this kubeconfig expires at ${SKE_EXPIRES_AT}; rerun this script afterwards."
    fi

    echo ">> kubectl configured successfully."
    ;;

  local)
    require_command k3d "k3d CLI not found; install it to configure kubectl for local clusters."
    require_command kubectl "kubectl not found; install it to interact with Kubernetes."
    require_tf_outputs

    K3D_CLUSTER_NAME=$(tf_output_value "k3d_cluster_name")
    KUBECONFIG_CONTEXT=$(tf_output_value "kubeconfig_context")
    KUBECONFIG_PATH=$(tf_output_value "kubeconfig_path")

    if [[ -z "${K3D_CLUSTER_NAME}" || -z "${KUBECONFIG_CONTEXT}" || -z "${KUBECONFIG_PATH}" ]]; then
      echo ">> ERROR: Missing required Terraform outputs (k3d_cluster_name, kubeconfig_context, kubeconfig_path)." >&2
      exit 1
    fi

    echo ">> Generating/merging kubeconfig for k3d cluster '${K3D_CLUSTER_NAME}'..."

    # 1) Ensure the kubeconfig used by Terraform provisioning is populated.
    mkdir -p "$(dirname "${KUBECONFIG_PATH}")"
    k3d kubeconfig merge "${K3D_CLUSTER_NAME}" \
      --output "${KUBECONFIG_PATH}" \
      --kubeconfig-switch-context=false >/dev/null

    # 2) Also merge into the default kubeconfig so the context is available in new shells
    #    (i.e., when KUBECONFIG is not explicitly set).
    k3d kubeconfig merge "${K3D_CLUSTER_NAME}" \
      --kubeconfig-merge-default \
      --kubeconfig-switch-context=false >/dev/null

    echo ">> Switching kubectl context to '${KUBECONFIG_CONTEXT}'..."
    # We want the "global" current context (default kubeconfig), not just this shell session.
    unset KUBECONFIG || true
    kubectl config use-context "${KUBECONFIG_CONTEXT}"
    echo ">> kubectl configured successfully."
    ;;

  *)
    cat <<EOF
>> ERROR: This script must be run from the 'aws', 'azure', 'stackit', or 'local' directory.

Usage:
  cd aws     && ../scripts/configure-kubectl.sh
  # or
  cd azure   && ../scripts/configure-kubectl.sh
  # or
  cd stackit && ../scripts/configure-kubectl.sh
  # or
  cd local   && ../scripts/configure-kubectl.sh
EOF
    exit 1
    ;;
esac
