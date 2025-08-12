###
# Deploy all common Kubernetes resources (reusing modules/k8s-common)
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

  registry_dockerio = local.registry_dockerio
  registry_quayio   = local.registry_quayio
  registry_k8sio    = local.registry_k8sio

  helm_cert_manager_version   = var.helm_cert_manager_version
  helm_metrics_server_version = var.helm_metrics_server_version
  helm_gdcn_version           = var.helm_gdcn_version
  helm_pulsar_version         = var.helm_pulsar_version

  ingress_ip  = google_compute_address.ingress.address
  db_hostname = google_sql_database_instance.postgres.private_ip_address
  db_username = local.db_username
  db_password = local.db_password
  s3_endpoint_override = var.s3_endpoint_override

  depends_on = [
    google_container_cluster.primary,
    module.k8s_gcp
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


