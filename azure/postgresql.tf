###
# Provision Azure Database for PostgreSQL for GoodData.CN metadata
###

# Generate a strong password for the database
resource "random_password" "db_password" {
  length  = 32
  special = false
}

locals {
  db_username = "postgres"
  db_password = random_password.db_password.result
  # PostgreSQL sizing resolved in size-profiles.tf.
}

# Create Private DNS Zone for PostgreSQL
resource "azurerm_private_dns_zone" "postgresql" {
  name                = "${var.deployment_name}.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.main.name

  tags = local.common_tags
}

# Link Private DNS Zone to Virtual Network
resource "azurerm_private_dns_zone_virtual_network_link" "postgresql" {
  name                  = "${var.deployment_name}-postgresql-dns-link"
  private_dns_zone_name = azurerm_private_dns_zone.postgresql.name
  virtual_network_id    = azurerm_virtual_network.main.id
  resource_group_name   = azurerm_resource_group.main.name
  registration_enabled  = false

  tags = local.common_tags
}

# Create PostgreSQL Flexible Server
resource "azurerm_postgresql_flexible_server" "main" {
  name                   = "${var.deployment_name}-postgresql"
  resource_group_name    = azurerm_resource_group.main.name
  location               = azurerm_resource_group.main.location
  version                = "16"
  delegated_subnet_id    = azurerm_subnet.db.id
  private_dns_zone_id    = azurerm_private_dns_zone.postgresql.id
  administrator_login    = local.db_username
  administrator_password = local.db_password
  storage_mb             = local.postgresql_storage_mb
  sku_name               = local.postgresql_sku_name

  # Disable public network access when using VNet integration
  public_network_access_enabled = false

  backup_retention_days = 7
  auto_grow_enabled     = true

  maintenance_window {
    day_of_week  = 0
    start_hour   = 8
    start_minute = 0
  }

  tags = local.common_tags

  lifecycle {
    ignore_changes = [
      zone
    ]
  }

  depends_on = [
    azurerm_private_dns_zone_virtual_network_link.postgresql
  ]
}

resource "azurerm_postgresql_flexible_server_configuration" "trigram" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = "PG_TRGM"
}

# Performance parameters tuned by size_profile (see size-profiles.tf). Both are
# dynamic (no restart). shared_buffers/effective_cache_size are left to the SKU
# defaults, which scale with instance memory. Values are in kB.
resource "azurerm_postgresql_flexible_server_configuration" "work_mem" {
  name      = "work_mem"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = tostring(local.profile.postgres.work_mem_mb * 1024)
}

resource "azurerm_postgresql_flexible_server_configuration" "maintenance_work_mem" {
  name      = "maintenance_work_mem"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = tostring(local.profile.postgres.maintenance_work_mem_mb * 1024)
}
