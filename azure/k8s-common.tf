###
# Deploy all common Kubernetes resources
###

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
  gdcn_namespace     = var.gdcn_namespace
  gdcn_license_key   = var.gdcn_license_key
  gdcn_orgs          = var.gdcn_orgs
  size_profile       = var.size_profile
  cloud              = "azure"
  ingress_controller = var.ingress_controller

  letsencrypt_email       = var.letsencrypt_email
  auth_hostname           = var.auth_hostname
  tls_mode                = var.tls_mode
  ingress_nginx_behind_l7 = var.ingress_nginx_behind_l7

  enable_ai_features = var.enable_ai_features
  enable_image_cache = var.enable_image_cache
  registry_dockerio  = local.registry_dockerio
  registry_quayio    = local.registry_quayio
  registry_k8sio     = local.registry_k8sio

  helm_cert_manager_version  = var.helm_cert_manager_version
  helm_gdcn_version          = var.helm_gdcn_version
  helm_istio_version         = var.helm_istio_version
  helm_pulsar_version        = var.helm_pulsar_version
  helm_ingress_nginx_version = var.helm_ingress_nginx_version
  helm_prometheus_version    = var.helm_prometheus_version
  helm_loki_version          = var.helm_loki_version
  helm_promtail_version      = var.helm_promtail_version
  helm_tempo_version         = var.helm_tempo_version
  helm_grafana_version       = var.helm_grafana_version

  enable_observability   = var.enable_observability
  observability_hostname = var.observability_hostname

  db_hostname = azurerm_postgresql_flexible_server.main.fqdn
  db_username = local.db_username
  db_password = local.db_password

  # Azure-specific storage configuration
  azure_storage_account_name    = azurerm_storage_account.main.name
  azure_exports_container       = azurerm_storage_container.containers["exports"].name
  azure_quiver_container        = azurerm_storage_container.containers["quiver-cache"].name
  azure_datasource_fs_container = azurerm_storage_container.containers["quiver-datasource-fs"].name
  azure_uami_client_id          = azurerm_user_assigned_identity.gdcn.client_id

  depends_on = [
    azurerm_kubernetes_cluster.main,
    azurerm_role_assignment.gdcn_blob_contrib,
    azurerm_federated_identity_credential.gdcn,
  ]
}

output "auth_hostname" {
  description = "The hostname for Dex authentication ingress"
  value       = module.k8s_common.auth_hostname
}

output "enable_observability" {
  description = "Whether observability stack is enabled."
  value       = var.enable_observability
}

output "observability_hostname" {
  description = "Hostname used for Grafana ingress."
  value       = var.observability_hostname
}

output "org_domains" {
  description = "All GoodData.CN organization hostnames derived from gdcn_orgs"
  value       = module.k8s_common.org_domains
}

output "org_ids" {
  description = "List of organization IDs/DNS labels allowed by this deployment"
  value       = module.k8s_common.org_ids
}

# Query the ingress-nginx LoadBalancer IP via Azure CLI (no local kubectl needed)
data "external" "ingress_lb_ip" {
  count = var.ingress_controller == "ingress-nginx" ? 1 : 0

  program = [
    "bash", "-c",
    <<-EOT
      set -euo pipefail
      result=$(az aks command invoke \
        --resource-group "${azurerm_resource_group.main.name}" \
        --name "${azurerm_kubernetes_cluster.main.name}" \
        --command "kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}'" \
        --query "logs" -o tsv 2>/dev/null || echo "")
      # Clean up any whitespace/newlines
      ip=$(echo "$result" | tr -d '[:space:]')
      printf '{"ip":"%s"}' "$ip"
    EOT
  ]

  depends_on = [module.k8s_common]
}

data "external" "istio_ingress_lb_ip" {
  count = var.ingress_controller == "istio_gateway" ? 1 : 0

  program = [
    "bash", "-c",
    <<-EOT
      set -euo pipefail
      result=$(az aks command invoke \
        --resource-group "${azurerm_resource_group.main.name}" \
        --name "${azurerm_kubernetes_cluster.main.name}" \
        --command "kubectl get svc istio-ingress -n istio-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}'" \
        --query "logs" -o tsv 2>/dev/null || echo "")
      ip=$(echo "$result" | tr -d '[:space:]')
      printf '{"ip":"%s"}' "$ip"
    EOT
  ]

  depends_on = [module.k8s_common]
}

locals {
  # May be empty early in provisioning.
  ingress_lb_ip       = length(data.external.ingress_lb_ip) > 0 ? trimspace(try(data.external.ingress_lb_ip[0].result.ip, "")) : ""
  istio_ingress_lb_ip = length(data.external.istio_ingress_lb_ip) > 0 ? trimspace(try(data.external.istio_ingress_lb_ip[0].result.ip, "")) : ""
}

output "manual_dns_records" {
  description = "DNS records to create for Azure ingress."
  value = var.ingress_controller == "ingress-nginx" && local.ingress_lb_ip != "" ? [
    for hostname in distinct(compact(concat(
      [module.k8s_common.auth_hostname],
      module.k8s_common.org_domains,
      var.enable_observability ? [trimspace(var.observability_hostname)] : []
      ))) : {
      hostname    = hostname
      record_type = "A"
      value       = local.ingress_lb_ip
    }
    ] : (var.ingress_controller == "istio_gateway" && local.istio_ingress_lb_ip != "" ? [
      for hostname in distinct(compact(concat(
        [module.k8s_common.auth_hostname],
        module.k8s_common.org_domains,
        var.enable_observability ? [trimspace(var.observability_hostname)] : []
        ))) : {
        hostname    = hostname
        record_type = "A"
        value       = local.istio_ingress_lb_ip
      }
  ] : [])
}
