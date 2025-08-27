###
# Azure Load Balancer for nginx ingress
###

# Create a public IP for the nginx ingress LoadBalancer
resource "azurerm_public_ip" "ingress" {
  name                = "${var.deployment_name}-ingress-pip"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = merge(
    { 
      Project = var.deployment_name,
      Service = "nginx-ingress"
    },
    var.azure_additional_tags
  )
}
