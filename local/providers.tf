###
# Local (k3d) deployment providers
###

terraform {
  required_providers {
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
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.0"
    }
  }
}

locals {
  kubeconfig_path    = pathexpand(var.kubeconfig_path)
  kubeconfig_context = var.kubeconfig_context != "" ? var.kubeconfig_context : "k3d-${var.k3d_cluster_name}"
}

provider "kubernetes" {
  config_path    = local.kubeconfig_path
  config_context = local.kubeconfig_context
}

provider "helm" {
  kubernetes = {
    config_path    = local.kubeconfig_path
    config_context = local.kubeconfig_context
  }
}

provider "kubectl" {
  config_path    = local.kubeconfig_path
  config_context = local.kubeconfig_context
}

