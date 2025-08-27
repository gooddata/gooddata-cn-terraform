###
# Provision Azure Storage Account
###

# Create Storage Account for GoodData.CN.
# This storage account contains containers for:
# - quiver-cache: Query acceleration cache
# - quiver-datasource-fs: Data source files (e.g., uploaded CSVs)
# - exports: Exported reports or data

# Ensure the name is lower-case and contains no spaces or invalid chars
resource "random_id" "storage_suffix" {
  byte_length = 3
}

locals {
  # Sanitize deployment name and append a random 6-character
  # suffix for storage account name to make it globally unique
  storage_account_name = substr(
    replace(
      "${replace(lower(var.deployment_name), "[^0-9a-z]", "")}${random_id.storage_suffix.hex}",
      "-", ""
    ),
    0, 24
  )

  storage_containers = {
    quiver_cache  = "quiver-cache"
    datasource_fs = "quiver-datasource-fs"
    exports       = "exports"
  }
}

resource "azurerm_storage_account" "main" {
  name                     = local.storage_account_name
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  # Security settings - temporarily enable public access for initial setup
  public_network_access_enabled   = true
  allow_nested_items_to_be_public = false

  # Enable blob versioning
  blob_properties {
    versioning_enabled = true
    delete_retention_policy {
      days = 7
    }
    container_delete_retention_policy {
      days = 7
    }
  }

  tags = merge(
    { Project = var.deployment_name },
    var.azure_additional_tags
  )
}

# Create storage containers (after private endpoint is configured)
resource "azurerm_storage_container" "containers" {
  for_each              = local.storage_containers
  name                  = each.value
  storage_account_id    = azurerm_storage_account.main.id
  container_access_type = "private"

  depends_on = [
    azurerm_private_endpoint.storage,
    azurerm_private_dns_a_record.storage
  ]
}

# Create Private Endpoint for Storage Account
resource "azurerm_private_endpoint" "storage" {
  name                = "${var.deployment_name}-storage-pe"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.aks.id

  private_service_connection {
    name                           = "${var.deployment_name}-storage-psc"
    private_connection_resource_id = azurerm_storage_account.main.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  tags = merge(
    { Project = var.deployment_name },
    var.azure_additional_tags
  )
}

# Create Private DNS Zone for Storage Account
resource "azurerm_private_dns_zone" "storage" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.main.name

  tags = merge(
    { Project = var.deployment_name },
    var.azure_additional_tags
  )
}

# Link Private DNS Zone to Virtual Network
resource "azurerm_private_dns_zone_virtual_network_link" "storage" {
  name                  = "${var.deployment_name}-storage-dns-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.storage.name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false

  tags = merge(
    { Project = var.deployment_name },
    var.azure_additional_tags
  )
}

# Create DNS record for Private Endpoint
resource "azurerm_private_dns_a_record" "storage" {
  name                = azurerm_storage_account.main.name
  zone_name           = azurerm_private_dns_zone.storage.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 300
  records             = [azurerm_private_endpoint.storage.private_service_connection[0].private_ip_address]

  tags = merge(
    { Project = var.deployment_name },
    var.azure_additional_tags
  )
}
