###
# Provision Virtual Network
###

locals {
  vnet_cidr = "10.0.0.0/16"

  # Define subnet CIDRs - using larger subnet for AKS to accommodate more nodes
  aks_subnet_cidr = "10.0.0.0/22" # Provides ~1000 IPs instead of ~250
  db_subnet_cidr  = "10.0.4.0/24" # Moved to avoid overlap

}

resource "azurerm_virtual_network" "main" {
  name                = "${var.deployment_name}-vnet"
  address_space       = [local.vnet_cidr]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  tags = merge(
    { Project = var.deployment_name },
    var.azure_additional_tags
  )
}

# Subnet for AKS nodes
resource "azurerm_subnet" "aks" {
  name                 = "${var.deployment_name}-aks-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [local.aks_subnet_cidr]
}

# Subnet for database (with delegation for PostgreSQL)
resource "azurerm_subnet" "db" {
  name                 = "${var.deployment_name}-db-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [local.db_subnet_cidr]

  delegation {
    name = "postgresql-delegation"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# Network Security Group for AKS subnet
resource "azurerm_network_security_group" "aks" {
  name                = "${var.deployment_name}-aks-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  # Allow Azure LoadBalancer to access NodePorts
  # Traffic flow: Internet → Azure LoadBalancer → NodePorts → nginx Ingress → Services

  # Allow LoadBalancer access to HTTP NodePort
  security_rule {
    name                       = "allow-lb-http-nodeport"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "30000-32767" # NodePort range
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  # Allow LoadBalancer health checks  
  security_rule {
    name                       = "allow-lb-health-check"
    priority                   = 101
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "10254" # nginx health check port
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  # Allow VNet internal traffic to NodePorts (for internal communication)
  security_rule {
    name                       = "allow-vnet-nodeports"
    priority                   = 102
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "30000-32767"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }

  # Allow Internet access to HTTP/HTTPS ports for Load Balancer traffic forwarding
  # Note: Azure Load Balancer forwards Internet traffic directly to NodePort services
  # The source appears as Internet, not AzureLoadBalancer for this traffic flow
  security_rule {
    name                       = "allow-internet-http-https"
    priority                   = 103
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["80", "443"]
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  tags = merge(
    { Project = var.deployment_name },
    var.azure_additional_tags
  )
}

# Associate NSG with AKS subnet
resource "azurerm_subnet_network_security_group_association" "aks" {
  subnet_id                 = azurerm_subnet.aks.id
  network_security_group_id = azurerm_network_security_group.aks.id
}

# Network Security Group for database subnet
resource "azurerm_network_security_group" "db" {
  name                = "${var.deployment_name}-db-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  # Allow PostgreSQL traffic from AKS subnet
  security_rule {
    name                       = "allow-postgresql"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "5432"
    source_address_prefix      = local.aks_subnet_cidr
    destination_address_prefix = "*"
  }

  tags = merge(
    { Project = var.deployment_name },
    var.azure_additional_tags
  )
}

# Associate NSG with database subnet
resource "azurerm_subnet_network_security_group_association" "db" {
  subnet_id                 = azurerm_subnet.db.id
  network_security_group_id = azurerm_network_security_group.db.id
}


