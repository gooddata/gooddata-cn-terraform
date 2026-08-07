###
# Provision AKS cluster
###

# Sizing resolved in size-profiles.tf: system_node_vm_size sizes the system
# pool; workload nodes come from Node Auto Provisioning (see karpenter.tf).

# Create the AKS cluster
resource "azurerm_kubernetes_cluster" "main" {
  name                = var.deployment_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  dns_prefix          = var.deployment_name
  kubernetes_version  = var.aks_version

  # Standard tier: API-server uptime SLA (99.95% with AZs) + scaled control plane.
  sku_tier = "Standard"

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # Enable Azure RBAC for Kubernetes authorization
  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = var.azure_tenant_id
  }

  dynamic "api_server_access_profile" {
    for_each = length(var.aks_api_server_authorized_ip_ranges) > 0 ? [true] : []
    content {
      authorized_ip_ranges = var.aks_api_server_authorized_ip_ranges
    }
  }

  # Fixed-size system node pool. Hosts cluster-critical system pods; all
  # workload capacity is provisioned just-in-time by Node Auto Provisioning
  # (managed Karpenter, enabled below). Sized by system_node_vm_size.
  default_node_pool {
    name           = "default"
    vm_size        = local.system_node_vm_size
    vnet_subnet_id = azurerm_subnet.aks.id
    node_count     = local.aks_min_nodes
    # Spread system nodes across all 3 AZs (also unlocks the 99.95% API SLA and
    # zone-redundant / Premium SSD v2 workloads).
    zones           = ["1", "2", "3"]
    max_pods        = 110
    os_disk_size_gb = 100
    # CriticalAddonsOnly taint: reserve the system pool for system/critical pods
    # so workloads can't starve CoreDNS, metrics-server, or the NAP controller.
    only_critical_addons_enabled = true

    upgrade_settings {
      max_surge = "2"
    }

    tags = local.common_tags
  }

  # Node Auto Provisioning (NAP / managed Karpenter): mode=Auto installs and
  # manages Karpenter in the control plane; default_node_pools=None means the
  # only NodePools are the ones we define (karpenter.tf). NAP cannot coexist
  # with the cluster autoscaler, so node-pool autoscaling must stay unset.
  node_provisioning_profile {
    mode               = "Auto"
    default_node_pools = "None"
  }

  # Identity configuration
  identity {
    type = "SystemAssigned"
  }

  # Azure CNI Overlay powered by Cilium: pods get IPs from pod_cidr, not the AKS
  # subnet, so node count isn't subnet-bound. Overlay requires Cilium (not NPM).
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "cilium"
    network_data_plane  = "cilium"
    pod_cidr            = "10.244.0.0/16"
    dns_service_ip      = "10.2.0.10"
    service_cidr        = "10.2.0.0/24"
    load_balancer_sku   = "standard"
    # Egress via the managed NAT gateway (nat-gateway.tf) to avoid SNAT exhaustion.
    outbound_type = "userAssignedNATGateway"
  }

  # Add-ons
  azure_policy_enabled             = true
  http_application_routing_enabled = false

  tags = local.common_tags

  # userAssignedNATGateway egress needs both bound before creation, and keeps node
  # egress alive until the cluster is destroyed.
  depends_on = [
    azurerm_nat_gateway_public_ip_association.main,
    azurerm_subnet_nat_gateway_association.aks,
  ]
}

# The kubelet identity gets no resource-group-wide grant: any pod can reach it
# via IMDS. Real needs use scoped identities (AcrPull below, UAMIs in identity.tf).

# Grant AKS cluster's system identity Network Contributor permissions for LoadBalancer services
resource "azurerm_role_assignment" "aks_system_identity_network_contributor" {
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.main.identity[0].principal_id
}

# Grant AKS cluster permissions to pull from ACR (if using ACR)
resource "azurerm_role_assignment" "aks_acr_pull" {
  count                = var.enable_image_cache ? 1 : 0
  scope                = azurerm_container_registry.main[0].id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
}

# Grant the current principal (cluster creator) cluster admin permissions
resource "azurerm_role_assignment" "aks_creator_cluster_admin" {
  scope                = azurerm_kubernetes_cluster.main.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Outputs
output "aks_cluster_name" {
  description = "Name of the AKS cluster"
  value       = azurerm_kubernetes_cluster.main.name
}
