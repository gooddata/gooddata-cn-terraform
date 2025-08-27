###
# Provision Virtual Network
###

locals {
  vnet_cidr = "10.0.0.0/16"
  
  # Define subnet CIDRs - using larger subnet for AKS to accommodate more nodes
  aks_subnet_cidr         = "10.0.0.0/22"   # Provides ~1000 IPs instead of ~250
  db_subnet_cidr          = "10.0.4.0/24"   # Moved to avoid overlap

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

  # Allow HTTP traffic from internet
  security_rule {
    name                       = "allow-http"
    priority                   = 1000
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # Allow HTTPS traffic from internet
  security_rule {
    name                       = "allow-https"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
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


