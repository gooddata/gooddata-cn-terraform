###
# Provision AKS cluster
###

# AKS will use system-assigned managed identity for simplified authentication

# Create Log Analytics Workspace for AKS monitoring
resource "azurerm_log_analytics_workspace" "aks" {
  name                = "${var.deployment_name}-aks-logs"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = 30

  tags = merge(
    { Project = var.deployment_name },
    var.azure_additional_tags
  )
}

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

  # Default node pool
  default_node_pool {
    name                 = "default"
    vm_size              = var.aks_node_vm_size
    vnet_subnet_id       = azurerm_subnet.aks.id
    auto_scaling_enabled = var.aks_enable_auto_scaling
    min_count            = var.aks_enable_auto_scaling ? var.aks_min_nodes : null
    max_count            = var.aks_enable_auto_scaling ? var.aks_max_nodes : null
    node_count           = var.aks_enable_auto_scaling ? null : var.aks_min_nodes
    max_pods             = 110
    os_disk_size_gb      = 30
    type                 = "VirtualMachineScaleSets"

    upgrade_settings {
      max_surge = "1"
    }

    tags = merge(
      {
        Project = var.deployment_name
      },
      var.azure_additional_tags
    )
  }

  # Cluster autoscaler profile
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

  # Monitoring
  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.aks.id
  }

  # Add-ons
  azure_policy_enabled             = true
  http_application_routing_enabled = false



  tags = merge(
    { Project = var.deployment_name },
    var.azure_additional_tags
  )

  depends_on = [
    azurerm_subnet.aks
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
  count                = var.acr_cache_images ? 1 : 0
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
