###
# Provision an ECR pull-through cache for Docker Hub to avoid rate limits
###

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# Anything you pull via:
#   <acct>.dkr.ecr.<region>.amazonaws.com/<prefix>/<image>:<tag>
# is proxied/cached from the upstream registry.

resource "aws_secretsmanager_secret" "dockerio" {
  name        = "ecr-pullthroughcache/${var.deployment_name}-dockerio"
  description = "Credentials for Docker Hub used by ECR pull-through cache."
}

resource "aws_secretsmanager_secret_version" "dockerio" {
  secret_id = aws_secretsmanager_secret.dockerio.id

  # Store your Docker Hub credentials as Terraform variables
  secret_string = jsonencode({
    username    = var.dockerhub_username
    accessToken = var.dockerhub_access_token
  })
}

resource "aws_ecr_pull_through_cache_rule" "dockerio" {
  ecr_repository_prefix = "dockerio"
  upstream_registry_url = "registry-1.docker.io"
  credential_arn        = aws_secretsmanager_secret.dockerio.arn
}
resource "aws_ecr_pull_through_cache_rule" "quayio" {
  ecr_repository_prefix = "quayio"
  upstream_registry_url = "quay.io"
}

resource "aws_ecr_pull_through_cache_rule" "registryk8sio" {
  ecr_repository_prefix = "registryk8sio"
  upstream_registry_url = "registry.k8s.io"
}
