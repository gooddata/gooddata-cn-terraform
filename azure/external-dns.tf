###
# Azure DNS automation via external-dns
#
# When dns_provider = "azure-dns", external-dns runs in the cluster, watches
# Ingress and Service resources, and maintains A/TXT records in the configured
# Azure DNS zone. Mirrors the AWS Route 53 wiring in modules/k8s-aws/external-dns.tf.
###

locals {
  external_dns_enabled      = var.dns_provider == "azure-dns"
  external_dns_namespace    = "external-dns"
  external_dns_txt_owner_id = trimspace(var.deployment_name)
  external_dns_zone_rg      = local.external_dns_enabled ? trimspace(var.azure_dns_zone_resource_group_name) : ""
  external_dns_zone_name    = local.external_dns_enabled ? trimspace(var.azure_dns_zone_name) : ""

  # All hostnames Terraform expects to surface via DNS.
  external_dns_managed_hosts = local.external_dns_enabled ? distinct(compact(concat(
    [trimspace(var.auth_hostname)],
    [for org in var.gdcn_orgs : trimspace(org.hostname)],
    var.enable_observability ? [trimspace(var.observability_hostname)] : [],
    var.enable_llm_observability ? [trimspace(var.llm_observability_hostname)] : []
  ))) : []

  # Hostnames that aren't a subdomain of the configured zone — these would never
  # match the zone filter and indicate a misconfiguration.
  external_dns_invalid_hosts = local.external_dns_enabled ? [
    for host in local.external_dns_managed_hosts : host
    if !(host == local.external_dns_zone_name || endswith(host, ".${local.external_dns_zone_name}"))
  ] : []
}

data "azurerm_dns_zone" "external_dns" {
  count = local.external_dns_enabled ? 1 : 0

  name                = local.external_dns_zone_name
  resource_group_name = local.external_dns_zone_rg
}

resource "terraform_data" "validate_azure_dns_hostnames" {
  count = local.external_dns_enabled ? 1 : 0

  lifecycle {
    precondition {
      condition     = length(local.external_dns_invalid_hosts) == 0
      error_message = "auth_hostname, gdcn_orgs[*].hostname, observability_hostname (when enable_observability=true) and llm_observability_hostname (when enable_llm_observability=true) must be within Azure DNS zone '${local.external_dns_zone_name}'. Invalid: ${join(", ", local.external_dns_invalid_hosts)}"
    }
  }
}

# UAMI granted DNS Zone Contributor on the target zone, federated to the
# external-dns Kubernetes service account via workload identity.
resource "azurerm_user_assigned_identity" "external_dns" {
  count = local.external_dns_enabled ? 1 : 0

  name                = "${var.deployment_name}-external-dns-uami"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  tags = local.common_tags
}

resource "azurerm_role_assignment" "external_dns_zone_contributor" {
  count = local.external_dns_enabled ? 1 : 0

  scope                = data.azurerm_dns_zone.external_dns[0].id
  role_definition_name = "DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.external_dns[0].principal_id
}

data "azurerm_resource_group" "external_dns_zone" {
  count = local.external_dns_enabled ? 1 : 0

  name = local.external_dns_zone_rg
}

# external-dns discovers zones with a resource-group-scoped list, which the
# zone-scoped assignment above does not authorize. Without this it 403s on every sync.
resource "azurerm_role_assignment" "external_dns_zone_rg_reader" {
  count = local.external_dns_enabled ? 1 : 0

  scope                = data.azurerm_resource_group.external_dns_zone[0].id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.external_dns[0].principal_id
}

resource "azurerm_federated_identity_credential" "external_dns" {
  count = local.external_dns_enabled ? 1 : 0

  name                      = "external-dns-workload"
  user_assigned_identity_id = azurerm_user_assigned_identity.external_dns[0].id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject                   = "system:serviceaccount:${local.external_dns_namespace}:external-dns"
}

resource "kubernetes_namespace_v1" "external_dns" {
  count = local.external_dns_enabled ? 1 : 0

  metadata {
    name = local.external_dns_namespace
  }

  # Azure RBAC is on and the provider uses the non-admin kubeconfig, so this
  # grant is what authorizes every Kubernetes API call below.
  depends_on = [azurerm_role_assignment.aks_creator_cluster_admin]
}

# external-dns's Azure provider reads its config from a file (default
# /etc/kubernetes/azure.json), NOT from env vars. Provide it as a Secret;
# useWorkloadIdentityExtension makes it auth via the federated SA token that the
# workload-identity webhook injects (no client secret needed).
resource "kubernetes_secret_v1" "external_dns_azure" {
  count = local.external_dns_enabled ? 1 : 0

  metadata {
    name      = "external-dns-azure-config"
    namespace = kubernetes_namespace_v1.external_dns[0].metadata[0].name
  }

  data = {
    "azure.json" = jsonencode({
      tenantId                     = data.azurerm_client_config.current.tenant_id
      subscriptionId               = data.azurerm_client_config.current.subscription_id
      resourceGroup                = local.external_dns_zone_rg
      useWorkloadIdentityExtension = true
    })
  }

  depends_on = [azurerm_role_assignment.aks_creator_cluster_admin]
}

resource "helm_release" "external_dns" {
  count = local.external_dns_enabled ? 1 : 0

  name          = "external-dns"
  repository    = "https://kubernetes-sigs.github.io/external-dns/"
  chart         = "external-dns"
  version       = var.helm_external_dns_version
  namespace     = kubernetes_namespace_v1.external_dns[0].metadata[0].name
  wait          = true
  wait_for_jobs = true
  timeout       = 1800

  values = [yamlencode({
    image = {
      repository = "${local.registry_k8sio}/external-dns/external-dns"
    }
    provider      = "azure"
    policy        = "sync"
    registry      = "txt"
    txtOwnerId    = local.external_dns_txt_owner_id
    txtPrefix     = "gdcn-"
    domainFilters = [local.external_dns_zone_name]
    sources       = var.ingress_controller == "istio_gateway" ? ["service"] : ["ingress"]

    serviceAccount = {
      create = true
      name   = "external-dns"
      annotations = {
        "azure.workload.identity/client-id" = azurerm_user_assigned_identity.external_dns[0].client_id
      }
      labels = {
        "azure.workload.identity/use" = "true"
      }
    }

    podLabels = {
      "azure.workload.identity/use" = "true"
    }

    # Mount azure.json (the Secret above) at the provider's default config path.
    extraVolumes = [{
      name   = "azure-config-file"
      secret = { secretName = kubernetes_secret_v1.external_dns_azure[0].metadata[0].name }
    }]
    extraVolumeMounts = [{
      name      = "azure-config-file"
      mountPath = "/etc/kubernetes"
      readOnly  = true
    }]
  })]

  # Deliberately does NOT depend on module.k8s_common: external-dns watches for
  # Ingresses/Services, so it can start first, and k8s_common depends on it so
  # DNS resolves before cert-manager opens its first ACME HTTP-01 challenge.
  depends_on = [
    azurerm_role_assignment.external_dns_zone_contributor,
    azurerm_role_assignment.external_dns_zone_rg_reader,
    azurerm_federated_identity_credential.external_dns,
    terraform_data.validate_azure_dns_hostnames,
    # Image comes from the k8sio cache rule when enable_image_cache is set.
    azurerm_container_registry_cache_rule.k8sio,
    azurerm_role_assignment.aks_acr_pull,
  ]
}

output "azure_dns_zone_name_servers" {
  description = "Name servers for the Azure DNS zone (when dns_provider = \"azure-dns\"). Configure these at your domain registrar to delegate the zone to Azure DNS."
  value       = local.external_dns_enabled ? data.azurerm_dns_zone.external_dns[0].name_servers : []
}
