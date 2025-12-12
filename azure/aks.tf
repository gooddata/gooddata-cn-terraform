###
# Provision AKS cluster
###

# Create the AKS cluster
resource "azurerm_kubernetes_cluster" "main" {
  name                = var.deployment_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  dns_prefix          = var.deployment_name
  kubernetes_version  = var.aks_version

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

  # Default node pool
  default_node_pool {
    name                 = "default"
    vm_size              = var.aks_node_vm_size
    vnet_subnet_id       = azurerm_subnet.aks.id
    auto_scaling_enabled = true
    min_count            = var.aks_min_nodes
    max_count            = var.aks_max_nodes
    node_count           = null
    max_pods             = 110
    os_disk_size_gb      = 100

    upgrade_settings {
      max_surge = "2"
    }

    tags = local.common_tags
  }

  auto_scaler_profile {
    expander = "least-waste"
  }

  # Identity configuration
  identity {
    type = "SystemAssigned"
  }

  # Network configuration
  network_profile {
    network_plugin    = "azure"
    network_policy    = "azure"
    dns_service_ip    = "10.2.0.10"
    service_cidr      = "10.2.0.0/24"
    load_balancer_sku = "standard"
  }

  # Add-ons
  azure_policy_enabled             = true
  http_application_routing_enabled = false



  tags = local.common_tags

  depends_on = [
    azurerm_subnet.aks,
    azurerm_container_registry.main,
    azurerm_container_registry_cache_rule.dockerio,
    azurerm_container_registry_cache_rule.quayio,
    azurerm_container_registry_cache_rule.k8sio,
    azurerm_container_registry_credential_set.dockerio
  ]
}

# Grant AKS cluster permissions to manage the resource group
resource "azurerm_role_assignment" "aks_cluster_contributor" {
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
}

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
