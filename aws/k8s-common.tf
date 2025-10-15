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

  deployment_name            = var.deployment_name
  gdcn_license_key           = var.gdcn_license_key
  letsencrypt_email          = var.letsencrypt_email
  wildcard_dns_provider      = var.wildcard_dns_provider
  gdcn_replica_count         = var.gdcn_replica_count
  aws_region                 = var.aws_region
  s3_quiver_cache_bucket_id  = aws_s3_bucket.buckets["quiver_cache"].id
  s3_datasource_fs_bucket_id = aws_s3_bucket.buckets["datasource_fs"].id
  s3_exports_bucket_id       = aws_s3_bucket.buckets["exports"].id

  registry_dockerio = local.registry_dockerio
  registry_quayio   = local.registry_quayio
  registry_k8sio    = local.registry_k8sio

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
    aws_ecr_pull_through_cache_rule.quayio,
    aws_ecr_pull_through_cache_rule.k8sio,
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
