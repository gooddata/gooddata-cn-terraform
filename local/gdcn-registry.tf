###
# Credentials for a private gooddata-cn chart/image registry
###

locals {
  # <account>.dkr.ecr.<region>.amazonaws.com — ECR mints its own short-lived token,
  # so no username/password belongs in settings.tfvars for such a host.
  gdcn_registry_ecr_parts  = regexall("^[0-9]+\\.dkr\\.ecr\\.([a-z0-9-]+)\\.amazonaws\\.com$", trimspace(var.gdcn_registry_server))
  gdcn_registry_is_ecr     = length(local.gdcn_registry_ecr_parts) > 0
  gdcn_registry_ecr_region = local.gdcn_registry_is_ecr ? local.gdcn_registry_ecr_parts[0][0] : ""

  gdcn_registry_username = local.gdcn_registry_is_ecr ? "AWS" : var.gdcn_registry_username
  gdcn_registry_password = local.gdcn_registry_is_ecr ? data.external.gdcn_ecr_token[0].result.password : var.gdcn_registry_password
}

# Re-read on every plan/apply, so the 12-hour ECR token is always current.
# Uses the AWS CLI rather than the AWS provider, which would demand credentials
# from every local deployment whether or not it targets ECR.
data "external" "gdcn_ecr_token" {
  count = local.gdcn_registry_is_ecr ? 1 : 0

  program = [
    "bash",
    "-c",
    <<-EOT
      set -euo pipefail

      if ! command -v aws >/dev/null 2>&1; then
        echo "aws CLI is required to authenticate against ${var.gdcn_registry_server}." >&2
        exit 1
      fi

      token="$(aws ecr get-login-password --region ${local.gdcn_registry_ecr_region} ${var.aws_profile_name != "" ? "--profile ${var.aws_profile_name}" : ""})"

      printf '{"password":"%s"}' "$token"
    EOT
  ]
}
