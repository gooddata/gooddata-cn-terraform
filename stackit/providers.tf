###
# Configure required providers
###

terraform {
  required_version = ">= 1.9"
  required_providers {
    # Pinned to a minor range: the provider is pre-1.0 and ships breaking
    # changes between minors.
    stackit = {
      source  = "stackitcloud/stackit"
      version = "~> 0.107"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 3.0"
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

# Credentials come from the environment, not from tfvars: either the key flow
# (STACKIT_SERVICE_ACCOUNT_KEY_PATH, or ~/.stackit/credentials.json) or workload
# identity federation (STACKIT_USE_OIDC).
provider "stackit" {
  default_region = var.stackit_region
}

locals {
  # Only STACKIT network resources accept labels (see stackit_additional_labels).
  common_labels = merge(
    { Project = var.deployment_name },
    var.stackit_additional_labels
  )

  # SKE hands out a raw kubeconfig rather than an exec-credential plugin, so the
  # connection details are decoded out of it instead of shelled out for.
  kubeconfig      = yamldecode(stackit_ske_kubeconfig.main.kube_config)
  kube_cluster    = local.kubeconfig.clusters[0].cluster
  kube_user       = local.kubeconfig.users[0].user
  kube_host       = local.kube_cluster.server
  kube_ca         = base64decode(local.kube_cluster["certificate-authority-data"])
  kube_client_crt = try(base64decode(local.kube_user["client-certificate-data"]), null)
  kube_client_key = try(base64decode(local.kube_user["client-key-data"]), null)
  # Null unless SKE switches to a token-based kubeconfig; providers treat null
  # as unset, so cert and token auth both work without a config change.
  kube_token = try(local.kube_user["token"], null)
}

provider "kubernetes" {
  host                   = local.kube_host
  cluster_ca_certificate = local.kube_ca
  client_certificate     = local.kube_client_crt
  client_key             = local.kube_client_key
  token                  = local.kube_token
}

provider "helm" {
  kubernetes = {
    host                   = local.kube_host
    cluster_ca_certificate = local.kube_ca
    client_certificate     = local.kube_client_crt
    client_key             = local.kube_client_key
    token                  = local.kube_token
  }
}

provider "kubectl" {
  host                   = local.kube_host
  cluster_ca_certificate = local.kube_ca
  client_certificate     = local.kube_client_crt
  client_key             = local.kube_client_key
  token                  = local.kube_token
  load_config_file       = false
}
