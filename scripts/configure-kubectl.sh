#!/usr/bin/env bash
set -euo pipefail

# Configure kubectl to connect to the Kubernetes cluster provisioned by Terraform.
# Run this script from the aws/ or azure/ directory after running `terraform apply`.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

CURRENT_DIR=$(basename "$(pwd)")

case "${CURRENT_DIR}" in
  aws)
    require_command aws "AWS CLI not found; install it to configure kubectl."
    require_command kubectl "kubectl not found; install it to interact with Kubernetes."
    load_tf_outputs
    if ! has_tf_outputs; then
      echo ">> ERROR: Terraform outputs not available. Run 'terraform apply' first." >&2
      exit 1
    fi

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
    load_tf_outputs
    if ! has_tf_outputs; then
      echo ">> ERROR: Terraform outputs not available. Run 'terraform apply' first." >&2
      exit 1
    fi

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

    echo ">> kubectl configured successfully."
    ;;

  *)
    cat <<EOF
>> ERROR: This script must be run from the 'aws' or 'azure' directory.

Usage:
  cd aws   && ../scripts/configure-kubectl.sh
  # or
  cd azure && ../scripts/configure-kubectl.sh
EOF
    exit 1
    ;;
esac
