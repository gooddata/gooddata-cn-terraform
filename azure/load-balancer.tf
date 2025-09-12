###
# Load Balancer Management and Monitoring
###

# Public IP for ingress controller
resource "azurerm_public_ip" "ingress" {
  name                = "${var.deployment_name}-ingress-pip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = merge(
    {
      Service = "nginx-ingress"
    },
    { Project = var.deployment_name },
    var.azure_additional_tags
  )
}

# Public IP for AKS outbound traffic (for datasource connectivity)
resource "azurerm_public_ip" "aks_outbound" {
  name                = "${var.deployment_name}-aks-outbound-pip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = merge(
    {
      Service = "aks-outbound"
    },
    { Project = var.deployment_name },
    var.azure_additional_tags
  )
}

# Data source to check the AKS-managed Load Balancer
data "azurerm_lb" "aks_managed" {
  name                = "kubernetes"
  resource_group_name = "MC_${azurerm_resource_group.main.name}_${azurerm_kubernetes_cluster.main.name}_${replace(lower(var.azure_location), " ", "")}"

  depends_on = [
    azurerm_kubernetes_cluster.main,
    module.k8s_azure
  ]
}

# Output information about Load Balancer frontend IPs for monitoring
output "load_balancer_frontend_ips" {
  description = "Information about all Load Balancer frontend IP configurations"
  value = {
    managed_lb_name           = data.azurerm_lb.aks_managed.name
    managed_lb_resource_group = data.azurerm_lb.aks_managed.resource_group_name
    frontend_ip_configs = [
      for config in data.azurerm_lb.aks_managed.frontend_ip_configuration : {
        name      = config.name
        public_ip = config.public_ip_address_id != null ? config.public_ip_address_id : "private"
      }
    ]
  }
}

# Load Balancer monitoring information
output "load_balancer_cleanup_notice" {
  description = "Notice about Load Balancer IP management"
  value       = <<-EOT
    ✅ Outbound IP is now managed by Terraform: ${azurerm_public_ip.aks_outbound.ip_address}
    ✅ Inbound IP is managed by Terraform: ${azurerm_public_ip.ingress.ip_address}
    
    No manual cleanup should be needed for future deployments.
    Check 'load_balancer_frontend_ips' output to monitor Load Balancer configuration.
    EOT
}
