###
# Credentials for a private gooddata-cn chart/image registry
###

locals {
  internal_registry_server   = trimspace(var.internal_registry_server)
  use_internal_registry_auth = local.internal_registry_server != ""

  # <account>.dkr.ecr[-fips].<region>.amazonaws.com[.cn] — ECR mints its own
  # short-lived token, so no username/password is configured for such a host.
  internal_registry_ecr_region = try(regex("^[0-9]+\\.dkr\\.ecr(?:-fips)?\\.([a-z0-9-]+)\\.amazonaws\\.com(?:\\.cn)?$", local.internal_registry_server)[0], "")
  internal_registry_is_ecr     = local.internal_registry_ecr_region != ""

  internal_registry_username = local.internal_registry_is_ecr ? "AWS" : var.internal_registry_username
  internal_registry_password = local.internal_registry_is_ecr ? data.external.internal_ecr_token[0].result.password : var.internal_registry_password

  # Send chart credentials only when the chart repo is hosted on that registry.
  internal_chart_repo_host       = try(regex("^(?:[a-z0-9+.-]+://)?([^/]*)", var.internal_chart_repository)[0], "")
  internal_chart_repo_is_private = local.use_internal_registry_auth && local.internal_chart_repo_host == local.internal_registry_server
}

# Re-read on every plan/apply, so the 12-hour ECR token is always current.
# Uses the AWS CLI rather than the AWS provider, which configures eagerly and so
# would require AWS credentials from every deployment, ECR or not.
data "external" "internal_ecr_token" {
  count = local.internal_registry_is_ecr ? 1 : 0

  program = [
    "bash",
    "-c",
    <<-EOT
      set -euo pipefail

      if ! command -v aws >/dev/null 2>&1; then
        echo "aws CLI is required to authenticate against ${local.internal_registry_server}." >&2
        exit 1
      fi

      token="$(aws ecr get-login-password --region ${local.internal_registry_ecr_region} ${var.internal_registry_aws_profile != "" ? "--profile ${var.internal_registry_aws_profile}" : ""})"

      printf '{"password":"%s"}' "$token"
    EOT
  ]
}

# Pull secret for a private registry hosting the gooddata-cn images.
resource "kubernetes_secret_v1" "internal_registry" {
  count = local.use_internal_registry_auth ? 1 : 0

  metadata {
    name      = "internal-registry"
    namespace = var.gdcn_namespace
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (local.internal_registry_server) = {
          username = local.internal_registry_username
          password = local.internal_registry_password
          auth     = base64encode("${local.internal_registry_username}:${local.internal_registry_password}")
        }
      }
    })
  }

  lifecycle {
    precondition {
      # Empty credentials would produce a secret every registry rejects, and the
      # failure would only surface as ImagePullBackOff after the chart install.
      condition     = local.internal_registry_is_ecr || (local.internal_registry_username != "" && local.internal_registry_password != "")
      error_message = "internal_registry_username and internal_registry_password are required when internal_registry_server is not an ECR host."
    }
  }

  depends_on = [
    kubernetes_namespace_v1.gdcn,
  ]
}
