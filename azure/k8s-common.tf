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
    random     = random
    external   = external
  }

  deployment_name    = var.deployment_name
  gdcn_license_key   = var.gdcn_license_key
  gdcn_orgs          = var.gdcn_orgs
  cloud              = "azure"
  ingress_controller = var.ingress_controller

  base_domain           = var.base_domain
  ingress_ip            = azurerm_public_ip.ingress.ip_address
  letsencrypt_email     = var.letsencrypt_email
  wildcard_dns_provider = var.wildcard_dns_provider

  gdcn_replica_count              = var.gdcn_replica_count
  ingress_nginx_replica_count     = var.ingress_nginx_replica_count
  pulsar_zookeeper_replica_count  = var.pulsar_zookeeper_replica_count
  pulsar_bookkeeper_replica_count = var.pulsar_bookkeeper_replica_count
  pulsar_broker_replica_count     = var.pulsar_broker_replica_count

  enable_ai_features = var.enable_ai_features
  enable_image_cache = var.enable_image_cache
  registry_dockerio  = local.registry_dockerio
  registry_quayio    = local.registry_quayio
  registry_k8sio     = local.registry_k8sio

  helm_cert_manager_version  = var.helm_cert_manager_version
  helm_gdcn_version          = var.helm_gdcn_version
  helm_pulsar_version        = var.helm_pulsar_version
  helm_ingress_nginx_version = var.helm_ingress_nginx_version

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
    azurerm_role_assignment.gdcn_blob_contrib,
    azurerm_role_assignment.acr_credential_set_secrets_user,
    azurerm_role_assignment.aks_acr_pull,
    azurerm_user_assigned_identity.gdcn,
    azurerm_federated_identity_credential.gdcn
  ]
}

output "base_domain" {
  description = "Base domain used for GoodData hostnames"
  value       = module.k8s_common.base_domain
}

output "auth_domain" {
  description = "The hostname for Dex authentication ingress"
  value       = module.k8s_common.auth_domain
}

output "org_domains" {
  description = "All GoodData.CN organization hostnames derived from gdcn_orgs"
  value       = module.k8s_common.org_domains
}

output "org_ids" {
  description = "List of organization IDs/DNS labels allowed by this deployment"
  value       = module.k8s_common.org_ids
}

