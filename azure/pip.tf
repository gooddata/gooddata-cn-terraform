###
# Allocate static public IP for ingress-nginx load balancer
###

# Public IP for ingress controller
resource "azurerm_public_ip" "ingress" {
  name                = "${var.deployment_name}-ingress-pip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = local.common_tags
}

