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
    var.enable_observability ? [trimspace(var.observability_hostname)] : []
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
      error_message = "auth_hostname, gdcn_orgs[*].hostname, and observability_hostname (when enable_observability=true) must be within Azure DNS zone '${local.external_dns_zone_name}'. Invalid: ${join(", ", local.external_dns_invalid_hosts)}"
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

resource "azurerm_federated_identity_credential" "external_dns" {
  count = local.external_dns_enabled ? 1 : 0

  name      = "external-dns-workload"
  parent_id = azurerm_user_assigned_identity.external_dns[0].id
  audience  = ["api://AzureADTokenExchange"]
  issuer    = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject   = "system:serviceaccount:${local.external_dns_namespace}:external-dns"
}

resource "kubernetes_namespace_v1" "external_dns" {
  count = local.external_dns_enabled ? 1 : 0

  metadata {
    name = local.external_dns_namespace
    labels = {
      "azure.workload.identity/use" = "true"
    }
  }
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

    # The Azure provider for external-dns needs the resource group + subscription
    # of the DNS zone; surfacing them as env vars avoids mounting a config file.
    env = [
      { name = "AZURE_SUBSCRIPTION_ID", value = data.azurerm_client_config.current.subscription_id },
      { name = "AZURE_TENANT_ID", value = data.azurerm_client_config.current.tenant_id },
      { name = "AZURE_RESOURCE_GROUP", value = local.external_dns_zone_rg },
      { name = "AZURE_USE_WORKLOAD_IDENTITY_EXTENSION", value = "true" },
    ]
  })]

  depends_on = [
    azurerm_role_assignment.external_dns_zone_contributor,
    azurerm_federated_identity_credential.external_dns,
    terraform_data.validate_azure_dns_hostnames,
    # external-dns watches Ingress objects created by the gooddata-cn chart, so
    # it must come after the rest of the cluster is up. k8s_common owns those
    # Ingresses; depending on it here keeps the apply order sensible.
    module.k8s_common,
  ]
}

output "azure_dns_zone_name_servers" {
  description = "Name servers for the Azure DNS zone (when dns_provider = \"azure-dns\"). Configure these at your domain registrar to delegate the zone to Azure DNS."
  value       = local.external_dns_enabled ? data.azurerm_dns_zone.external_dns[0].name_servers : []
}
