###
# Credentials for a private gooddata-cn chart/image registry
###

locals {
  gdcn_registry_server   = trimspace(var.gdcn_registry_server)
  use_gdcn_registry_auth = local.gdcn_registry_server != ""

  # <account>.dkr.ecr[-fips].<region>.amazonaws.com[.cn] — ECR mints its own
  # short-lived token, so no username/password is configured for such a host.
  gdcn_registry_ecr_parts  = regexall("^[0-9]+\\.dkr\\.ecr(-fips)?\\.([a-z0-9-]+)\\.amazonaws\\.com(\\.cn)?$", local.gdcn_registry_server)
  gdcn_registry_is_ecr     = length(local.gdcn_registry_ecr_parts) > 0
  gdcn_registry_ecr_region = local.gdcn_registry_is_ecr ? local.gdcn_registry_ecr_parts[0][1] : ""

  gdcn_registry_username = local.gdcn_registry_is_ecr ? "AWS" : var.gdcn_registry_username
  gdcn_registry_password = local.gdcn_registry_is_ecr ? data.external.gdcn_ecr_token[0].result.password : var.gdcn_registry_password

  # Send chart credentials only when the chart repo sits on that same registry.
  gdcn_chart_repo_is_private = local.use_gdcn_registry_auth && strcontains(var.helm_gdcn_repository, local.gdcn_registry_server)
}

# Re-read on every plan/apply, so the 12-hour ECR token is always current.
# Uses the AWS CLI rather than the AWS provider, which configures eagerly and so
# would require AWS credentials from every deployment, ECR or not.
data "external" "gdcn_ecr_token" {
  count = local.gdcn_registry_is_ecr ? 1 : 0

  program = [
    "bash",
    "-c",
    <<-EOT
      set -euo pipefail

      if ! command -v aws >/dev/null 2>&1; then
        echo "aws CLI is required to authenticate against ${local.gdcn_registry_server}." >&2
        exit 1
      fi

      token="$(aws ecr get-login-password --region ${local.gdcn_registry_ecr_region} ${var.gdcn_registry_aws_profile != "" ? "--profile ${var.gdcn_registry_aws_profile}" : ""})"

      printf '{"password":"%s"}' "$token"
    EOT
  ]
}

# Pull secret for a private registry hosting the gooddata-cn images.
resource "kubernetes_secret_v1" "gdcn_registry" {
  count = local.use_gdcn_registry_auth ? 1 : 0

  metadata {
    name      = "gdcn-registry"
    namespace = var.gdcn_namespace
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (local.gdcn_registry_server) = {
          username = local.gdcn_registry_username
          password = local.gdcn_registry_password
          auth     = base64encode("${local.gdcn_registry_username}:${local.gdcn_registry_password}")
        }
      }
    })
  }

  lifecycle {
    precondition {
      # Empty credentials would produce a secret every registry rejects, and the
      # failure would only surface as ImagePullBackOff after the chart install.
      condition     = local.gdcn_registry_is_ecr || (local.gdcn_registry_username != "" && local.gdcn_registry_password != "")
      error_message = "gdcn_registry_username and gdcn_registry_password are required when gdcn_registry_server is not an ECR host."
    }
  }

  depends_on = [
    kubernetes_namespace_v1.gdcn,
  ]
}
