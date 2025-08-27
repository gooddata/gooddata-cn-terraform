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

  registry_dockerio = local.registry_dockerio
  registry_quayio   = local.registry_quayio
  registry_k8sio    = local.registry_k8sio

  helm_cert_manager_version   = var.helm_cert_manager_version
  helm_metrics_server_version = var.helm_metrics_server_version
  helm_gdcn_version           = var.helm_gdcn_version
  helm_pulsar_version         = var.helm_pulsar_version

  # Disable metrics-server for Azure (AKS provides its own)
  deploy_metrics_server = false
  
  # GoodData.CN replica count for HA
  gdcn_replica_count = 1

  # Use the nginx ingress LoadBalancer external IP dynamically
  ingress_ip  = module.k8s_azure.ingress_external_ip
  db_hostname = azurerm_postgresql_flexible_server.main.fqdn
  db_username = local.db_username
  db_password = local.db_password

  depends_on = [
    azurerm_kubernetes_cluster.main,
    module.k8s_azure,
    azurerm_container_registry_cache_rule.dockerio,
    azurerm_container_registry_cache_rule.quayio
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
