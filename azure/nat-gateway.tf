###
# Managed NAT Gateway for AKS egress
###

# Dedicated outbound public IP for the NAT gateway (separate from the ingress LB IP).
resource "azurerm_public_ip" "nat" {
  name                = "${var.deployment_name}-nat-pip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = local.common_tags
}

# Regional NAT gateway (no zone) so it provides egress for nodes in all 3 zones.
# Gives 64k SNAT ports per IP vs the ~1k/node of default LB SNAT, eliminating
# SNAT port exhaustion under heavy outbound load.
resource "azurerm_nat_gateway" "main" {
  name                = "${var.deployment_name}-nat"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku_name            = "Standard"

  tags = local.common_tags
}

resource "azurerm_nat_gateway_public_ip_association" "main" {
  nat_gateway_id       = azurerm_nat_gateway.main.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

# Bind the NAT gateway to the AKS subnet. Must exist before the cluster is
# created when outbound_type = userAssignedNATGateway (see aks.tf depends_on).
resource "azurerm_subnet_nat_gateway_association" "aks" {
  subnet_id      = azurerm_subnet.aks.id
  nat_gateway_id = azurerm_nat_gateway.main.id
}
