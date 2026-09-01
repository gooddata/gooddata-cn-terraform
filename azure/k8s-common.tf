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

  deployment_name        = var.deployment_name
  gdcn_namespace         = var.gdcn_namespace
  gdcn_license_key       = var.gdcn_license_key
  gdcn_orgs              = var.gdcn_orgs
  gdcn_helm_extra_values = var.gdcn_helm_extra_values
  ingress_replicas       = local.profile.ingress_replicas
  gdcn_size              = local.profile.gdcn_size
  gdcn_storage_class     = local.storage_class
  pulsar_size            = local.profile.pulsar_size
  observability_size     = local.profile.observability_size
  cloud                  = "azure"
  ingress_controller     = var.ingress_controller

  letsencrypt_email       = var.letsencrypt_email
  auth_hostname           = var.auth_hostname
  tls_mode                = var.tls_mode
  ingress_nginx_behind_l7 = var.ingress_nginx_behind_l7

  enable_ai_features           = var.enable_ai_features
  enable_experimental_features = var.enable_experimental_features
  enable_matomo_telemetry      = var.enable_matomo_telemetry
  enable_image_cache           = var.enable_image_cache
  registry_dockerio            = local.registry_dockerio
  registry_quayio              = local.registry_quayio
  registry_k8sio               = local.registry_k8sio

  helm_cert_manager_version          = var.helm_cert_manager_version
  helm_gdcn_version                  = var.helm_gdcn_version
  helm_istio_version                 = var.helm_istio_version
  helm_pulsar_version                = var.helm_pulsar_version
  helm_ingress_nginx_version         = var.helm_ingress_nginx_version
  helm_kube_prometheus_stack_version = var.helm_kube_prometheus_stack_version
  helm_loki_version                  = var.helm_loki_version
  helm_promtail_version              = var.helm_promtail_version
  helm_tempo_version                 = var.helm_tempo_version
  helm_grafana_version               = var.helm_grafana_version

  enable_observability        = var.enable_observability
  observability_hostname      = var.observability_hostname
  loki_retention_period       = var.loki_retention_period
  prometheus_retention_period = var.prometheus_retention_period
  tempo_retention_period      = var.tempo_retention_period

  db_hostname = azurerm_postgresql_flexible_server.main.fqdn
  db_username = local.db_username
  db_password = local.db_password

  # Azure-specific storage configuration
  azure_storage_account_name    = azurerm_storage_account.main.name
  azure_exports_container       = azurerm_storage_container.containers["exports"].name
  azure_quiver_container        = azurerm_storage_container.containers["quiver-cache"].name
  azure_datasource_fs_container = azurerm_storage_container.containers["quiver-datasource-fs"].name
  azure_uami_client_id          = azurerm_user_assigned_identity.gdcn.client_id

  # Observability object storage: Loki + Tempo write to Blob (no big PVC),
  # authenticating via workload identity (obs UAMI federated to their SAs).
  loki_objstore = {
    object_store = "azure"
    storage = {
      type = "azure"
      # The SingleBinary chart references all three bucket names even with
      # ruler/admin features off; point them at the one loki container.
      bucketNames = {
        chunks = azurerm_storage_container.containers["loki"].name
        ruler  = azurerm_storage_container.containers["loki"].name
        admin  = azurerm_storage_container.containers["loki"].name
      }
      azure = {
        accountName       = azurerm_storage_account.main.name
        useFederatedToken = true
      }
    }
  }
  tempo_objstore = {
    backend = "azure"
    azure = {
      container_name       = azurerm_storage_container.containers["tempo"].name
      storage_account_name = azurerm_storage_account.main.name
      use_federated_token  = true
    }
    wal = { path = "/var/tempo/wal" }
  }
  obs_sa_annotations = {
    "azure.workload.identity/client-id" = azurerm_user_assigned_identity.observability.client_id
  }
  obs_pod_labels = {
    "azure.workload.identity/use" = "true"
  }

  depends_on = [
    azurerm_kubernetes_cluster.main,
    # Storage classes + the default-class annotations must exist before any Helm
    # release provisions PVCs, since every PVC references a class by name per profile.
    kubernetes_storage_class_v1.premium_ssd_v2,
    kubernetes_storage_class_v1.premium_ssd,
    kubernetes_annotations.default_storage_class,
    azurerm_role_assignment.gdcn_blob_contrib,
    azurerm_federated_identity_credential.gdcn,
    # Observability Blob access must exist before Loki/Tempo start.
    azurerm_role_assignment.observability_blob_contrib,
    azurerm_federated_identity_credential.loki,
    azurerm_federated_identity_credential.tempo,
    # Image cache plumbing must outlive the helm releases: pre-delete hooks
    # pull images via the cache rules, and kubelet needs AcrPull. Listing
    # these here makes destroy tear down k8s_common first, ACR plumbing after.
    azurerm_container_registry_cache_rule.dockerio,
    azurerm_container_registry_cache_rule.quayio,
    azurerm_container_registry_cache_rule.k8sio,
    azurerm_container_registry_credential_set.dockerio,
    azurerm_role_assignment.aks_acr_pull,
    azurerm_role_assignment.acr_credential_set_secrets_user,
    # DNS must resolve before cert-manager issues its first Let's Encrypt cert;
    # a failed issuance backs off up to 32h. No-op unless dns_provider=azure-dns.
    helm_release.external_dns,
    # Node capacity must outlive the helm releases too: deleting the NodePool
    # taints every Karpenter node, leaving pre-delete hooks unschedulable.
    kubectl_manifest.karpenter_node_pool,
    # Deleting a LoadBalancer Service needs subnet join, so this grant must
    # outlive the ingress release or the Azure LB can never be torn down.
    azurerm_role_assignment.aks_system_identity_network_contributor,
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
  gdcn_service_account_name = "gooddata-cn"
  # May be empty early in provisioning.
  ingress_lb_ip       = length(data.external.ingress_lb_ip) > 0 ? trimspace(try(data.external.ingress_lb_ip[0].result.ip, "")) : ""
  istio_ingress_lb_ip = length(data.external.istio_ingress_lb_ip) > 0 ? trimspace(try(data.external.istio_ingress_lb_ip[0].result.ip, "")) : ""
}

output "manual_dns_records" {
  description = "DNS records to create for Azure ingress. Empty when dns_provider = \"azure-dns\" — external-dns maintains the records automatically."
  value = local.external_dns_enabled ? [] : (
    var.ingress_controller == "ingress-nginx" && local.ingress_lb_ip != "" ? [
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
  )
}
