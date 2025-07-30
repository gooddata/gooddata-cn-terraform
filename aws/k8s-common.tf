###
# Deploy all common Kubernetes resources
###

module "k8s_common" {
  source = "../modules/k8s-common"

  providers = {
    kubernetes = kubernetes
    helm       = helm
    kubectl    = kubectl
  }

  deployment_name       = var.deployment_name
  gdcn_license_key      = var.gdcn_license_key
  letsencrypt_email     = var.letsencrypt_email
  wildcard_dns_provider = var.wildcard_dns_provider

  cache_dockerio = format(
    "%s.dkr.ecr.%s.amazonaws.com/%s",
    data.aws_caller_identity.current.account_id,
    data.aws_region.current.name,
    aws_ecr_pull_through_cache_rule.dockerio.ecr_repository_prefix
  )
  cache_quayio = format(
    "%s.dkr.ecr.%s.amazonaws.com/%s",
    data.aws_caller_identity.current.account_id,
    data.aws_region.current.name,
    aws_ecr_pull_through_cache_rule.quayio.ecr_repository_prefix
  )
  cache_registryk8sio = format(
    "%s.dkr.ecr.%s.amazonaws.com/%s",
    data.aws_caller_identity.current.account_id,
    data.aws_region.current.name,
    aws_ecr_pull_through_cache_rule.registryk8sio.ecr_repository_prefix
  )

  helm_cert_manager_version   = var.helm_cert_manager_version
  helm_metrics_server_version = var.helm_metrics_server_version
  helm_gdcn_version           = var.helm_gdcn_version
  helm_pulsar_version         = var.helm_pulsar_version

  ingress_ip  = aws_eip.lb[0].public_ip
  db_hostname = module.rds_postgresql.db_instance_address
  db_username = local.db_username
  db_password = local.db_password

  depends_on = [
    module.eks,
    module.k8s_aws,
    aws_ecr_pull_through_cache_rule.dockerio,
    aws_ecr_pull_through_cache_rule.quayio
  ]
}

output "auth_hostname" {
  description = "The hostname for Dex authentication ingress"
  value       = module.k8s_common.auth_hostname
}

output "gdcn_org_hostname" {
  description = "The hostname for GoodData.CN organization ingress"
  value       = module.k8s_common.gdcn_org_hostname
}
