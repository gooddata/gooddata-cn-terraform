###
# Deploy all common Kubernetes resources
###

locals {
  gdcn_namespace            = "gooddata-cn"
  gdcn_service_account_name = "gooddata-cn"
}

module "k8s_common" {
  source = "../modules/k8s-common"

  providers = {
    kubernetes = kubernetes
    helm       = helm
    kubectl    = kubectl
  }

  deployment_name           = var.deployment_name
  gdcn_license_key          = var.gdcn_license_key
  letsencrypt_email         = var.letsencrypt_email
  wildcard_dns_provider     = var.wildcard_dns_provider
  cloud                     = "azure"
  gdcn_namespace            = local.gdcn_namespace
  gdcn_service_account_name = local.gdcn_service_account_name
  gdcn_replica_count        = var.gdcn_replica_count

  registry_dockerio = local.registry_dockerio
  registry_quayio   = local.registry_quayio
  registry_k8sio    = local.registry_k8sio

  # Apply image cache overrides only when ACR cache is enabled
  use_image_cache = var.acr_cache_images

  helm_cert_manager_version  = var.helm_cert_manager_version
  helm_gdcn_version          = var.helm_gdcn_version
  helm_pulsar_version        = var.helm_pulsar_version
  helm_ingress_nginx_version = var.helm_ingress_nginx_version

  ingress_ip  = azurerm_public_ip.ingress.ip_address
  db_hostname = azurerm_postgresql_flexible_server.main.fqdn
  db_username = local.db_username
  db_password = local.db_password

  # Azure-specific storage configuration
  azure_storage_account_name    = azurerm_storage_account.main.name
  azure_exports_container       = azurerm_storage_container.containers["exports"].name
  azure_quiver_container        = azurerm_storage_container.containers["quiver-cache"].name
  azure_datasource_fs_container = azurerm_storage_container.containers["quiver-datasource-fs"].name
  azure_uami_client_id          = azurerm_user_assigned_identity.gdcn.client_id
  azure_resource_group_name     = azurerm_resource_group.main.name
  azure_ingress_pip_name        = azurerm_public_ip.ingress.name

  depends_on = [
    azurerm_kubernetes_cluster.main,
    azurerm_container_registry_cache_rule.dockerio,
    azurerm_container_registry_cache_rule.quayio,
    azurerm_container_registry_cache_rule.k8sio,
    azurerm_user_assigned_identity.gdcn,
    azurerm_federated_identity_credential.gdcn
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

