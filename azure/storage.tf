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
  # Create globally unique storage account name with 6-character random suffix
  # Sanitize deployment_name by removing non-alphanumeric characters for storage account naming
  storage_account_prefix = substr(join("", regexall("[0-9a-z]", lower(var.deployment_name))), 0, 18)
  storage_account_name   = "${local.storage_account_prefix}${random_id.storage_suffix.hex}"

  # List of storage containers needed for GoodData.CN
  storage_containers = [
    "quiver-cache",
    "quiver-datasource-fs",
    "exports"
  ]
}

resource "azurerm_storage_account" "main" {
  name                            = local.storage_account_name
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = true

  # Configure blob properties - no versioning needed for ephemeral data
  blob_properties {
    versioning_enabled = false
  }

  tags = local.common_tags
}

# Create storage containers
resource "azurerm_storage_container" "containers" {
  for_each              = toset(local.storage_containers)
  name                  = each.value
  storage_account_id    = azurerm_storage_account.main.id
  container_access_type = "private"
}
