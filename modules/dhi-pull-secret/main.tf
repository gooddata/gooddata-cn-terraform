###
# Docker Hardened Images (DHI): image pull secret in each given namespace
###

terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 3.0"
    }
  }
}

resource "kubernetes_secret_v1" "this" {
  for_each = var.namespaces

  metadata {
    name      = var.secret_name
    namespace = each.value
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (var.registry) = {
          username = var.username
          password = var.access_token
          auth     = base64encode("${var.username}:${var.access_token}")
        }
      }
    })
  }

  lifecycle {
    precondition {
      condition     = var.username != "" && var.access_token != ""
      error_message = "dockerhub_username and dockerhub_access_token are required: ${var.consumers} installed from Docker Hardened Images on dhi.io, which needs a Docker Hub login."
    }
  }
}
