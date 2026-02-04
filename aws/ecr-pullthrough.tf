###
# Provision an ECR pull-through cache for Docker Hub to avoid rate limits
###

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# If image caching is enabled, construct the registry URL. Otherwise, return the upstream one.
locals {
  upstream_registry_dockerio = "registry-1.docker.io"
  registry_dockerio = var.enable_image_cache ? format(
    "%s.dkr.ecr.%s.amazonaws.com/%s",
    data.aws_caller_identity.current.account_id,
    data.aws_region.current.id,
    aws_ecr_pull_through_cache_rule.dockerio[0].ecr_repository_prefix
  ) : local.upstream_registry_dockerio

  upstream_registry_quayio = "quay.io"
  registry_quayio = var.enable_image_cache ? format(
    "%s.dkr.ecr.%s.amazonaws.com/%s",
    data.aws_caller_identity.current.account_id,
    data.aws_region.current.id,
    aws_ecr_pull_through_cache_rule.quayio[0].ecr_repository_prefix
  ) : local.upstream_registry_quayio

  upstream_registry_k8sio = "registry.k8s.io"
  registry_k8sio = var.enable_image_cache ? format(
    "%s.dkr.ecr.%s.amazonaws.com/%s",
    data.aws_caller_identity.current.account_id,
    data.aws_region.current.id,
    aws_ecr_pull_through_cache_rule.k8sio[0].ecr_repository_prefix
  ) : local.upstream_registry_k8sio
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

resource "aws_ecr_pull_through_cache_rule" "dockerio" {
  count = var.enable_image_cache ? 1 : 0

  ecr_repository_prefix = "dockerio"
  upstream_registry_url = local.upstream_registry_dockerio
  credential_arn        = aws_secretsmanager_secret.dockerio[0].arn

  depends_on = [aws_secretsmanager_secret.dockerio]
}
resource "aws_ecr_pull_through_cache_rule" "quayio" {
  count = var.enable_image_cache ? 1 : 0

  ecr_repository_prefix = "quayio"
  upstream_registry_url = local.upstream_registry_quayio
}

resource "aws_ecr_pull_through_cache_rule" "k8sio" {
  count = var.enable_image_cache ? 1 : 0

  ecr_repository_prefix = "k8sio"
  upstream_registry_url = local.upstream_registry_k8sio
}
