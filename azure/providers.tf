###
# Configure required providers
###

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = ">= 2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.27"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.0.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.19.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6"
    }
    external = {
      source  = "hashicorp/external"
      version = ">= 2.0"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    key_vault {
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }
  }

  subscription_id = var.azure_subscription_id
  tenant_id       = var.azure_tenant_id
}

provider "azuread" {
  tenant_id = var.azure_tenant_id
}

# Data source to get the current client configuration
data "azurerm_client_config" "current" {}

locals {
  # Shared tags applied to all Azure resources
  common_tags = merge(
    { Project = var.deployment_name },
    var.azure_additional_tags
  )

  # Shared Kubernetes auth settings (kubelogin)
  kube_host = azurerm_kubernetes_cluster.main.kube_config[0].host
  kube_ca   = base64decode(azurerm_kubernetes_cluster.main.kube_config[0].cluster_ca_certificate)
  kubelogin_exec = {
    api_version = "client.authentication.k8s.io/v1"
    command     = "kubelogin"
    args = [
      "get-token",
      "--login", "azurecli",
      "--tenant-id", var.azure_tenant_id,
      "--server-id", "6dae42f8-4368-4678-94ff-3960e28e3630"
    ]
  }
}

# Kubernetes and Helm providers will connect to the AKS cluster using Azure RBAC credentials.
# These values are obtained from the AKS cluster data (set up in aks.tf).
provider "kubernetes" {
  host                   = local.kube_host
  cluster_ca_certificate = local.kube_ca
  exec {
    api_version = local.kubelogin_exec.api_version
    command     = local.kubelogin_exec.command
    args        = local.kubelogin_exec.args
  }
}

provider "helm" {
  kubernetes = {
    host                   = local.kube_host
    cluster_ca_certificate = local.kube_ca
    load_config_file       = false
    exec = {
      api_version = local.kubelogin_exec.api_version
      command     = local.kubelogin_exec.command
      args        = local.kubelogin_exec.args
    }
  }
}

provider "kubectl" {
  host                   = local.kube_host
  cluster_ca_certificate = local.kube_ca
  exec {
    api_version = local.kubelogin_exec.api_version
    command     = local.kubelogin_exec.command
    args        = local.kubelogin_exec.args
  }
  load_config_file = false
}
