###
# Configure required providers
###

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.0"
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

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile_name
  default_tags {
    tags = merge(
      { Project = var.deployment_name },
      var.additional_tags
    )
  }
}

# Kubernetes and Helm providers will connect to the EKS cluster using its API endpoint and token.
# These values are obtained from the EKS cluster data (set up in eks-cluster.tf).
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", module.eks.cluster_name,
      "--region", var.aws_region,
      "--profile", var.aws_profile_name
    ]
  }
}

provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    load_config_file       = false

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks", "get-token",
        "--cluster-name", module.eks.cluster_name,
        "--region", var.aws_region,
        "--profile", var.aws_profile_name
      ]
    }
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", module.eks.cluster_name,
      "--region", var.aws_region,
      "--profile", var.aws_profile_name
    ]
  }
  load_config_file = false
}
