###
# Provision an ECR pull-through cache for Docker Hub to avoid rate limits
###

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# If image caching is enabled, construct the registry URL. Otherwise, return the upstream one.
locals {
  ecr_registry_base = "${data.aws_caller_identity.current.account_id}.dkr.ecr${var.fips_enabled ? "-fips" : ""}.${data.aws_region.current.region}.amazonaws.com"

  upstream_registry_dockerio = "registry-1.docker.io"
  registry_dockerio = var.enable_image_cache ? (
    "${local.ecr_registry_base}/${aws_ecr_pull_through_cache_rule.dockerio[0].ecr_repository_prefix}"
  ) : local.upstream_registry_dockerio


}

# Anything you pull via:
#   <acct>.dkr.ecr.<region>.amazonaws.com/<prefix>/<image>:<tag>
# is proxied/cached from the upstream registry.

resource "random_id" "secret_suffix" {
  count = var.enable_image_cache ? 1 : 0

  byte_length = 3
}

resource "aws_secretsmanager_secret" "dockerio" {
  count = var.enable_image_cache ? 1 : 0

  name        = "ecr-pullthroughcache/${var.deployment_name}-${random_id.secret_suffix[0].hex}-dockerio"
  description = "Credentials for Docker Hub used by ECR pull-through cache."
}

resource "aws_secretsmanager_secret_version" "dockerio" {
  count = var.enable_image_cache ? 1 : 0

  secret_id = aws_secretsmanager_secret.dockerio[count.index].id

  # Store your Docker Hub credentials as Terraform variables
  secret_string = jsonencode({
    username    = var.dockerhub_username
    accessToken = var.dockerhub_access_token
  })
}

# ECR validates the secret ARN against an eventually-consistent index; the
# secret can be visible to GetSecretValue while CreatePullThroughCacheRule
# still returns SecretNotFoundException. Wait for propagation.
resource "time_sleep" "dockerio_secret_propagation" {
  count = var.enable_image_cache ? 1 : 0

  depends_on      = [aws_secretsmanager_secret_version.dockerio]
  create_duration = "30s"
}

resource "aws_ecr_pull_through_cache_rule" "dockerio" {
  count = var.enable_image_cache ? 1 : 0

  # Per deployment, so the cache repositories show the owner (ECR limit: 30 characters).
  ecr_repository_prefix = "${var.deployment_name}-dockerio"
  upstream_registry_url = local.upstream_registry_dockerio
  credential_arn        = aws_secretsmanager_secret.dockerio[0].arn

  depends_on = [time_sleep.dockerio_secret_propagation]

  lifecycle {
    precondition {
      condition     = length("${var.deployment_name}-dockerio") <= 30
      error_message = "enable_image_cache needs the ECR pull-through prefix \"<deployment_name>-dockerio\" to be at most 30 characters, so deployment_name can have at most 21 characters (now ${length(var.deployment_name)})."
    }
  }
}
