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
}

# Create Private DNS Zone for PostgreSQL
resource "azurerm_private_dns_zone" "postgresql" {
  name                = "${var.deployment_name}.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.main.name

  tags = merge(
    { Project = var.deployment_name },
    var.azure_additional_tags
  )
}

# Link Private DNS Zone to Virtual Network
resource "azurerm_private_dns_zone_virtual_network_link" "postgresql" {
  name                  = "${var.deployment_name}-postgresql-dns-link"
  private_dns_zone_name = azurerm_private_dns_zone.postgresql.name
  virtual_network_id    = azurerm_virtual_network.main.id
  resource_group_name   = azurerm_resource_group.main.name
  registration_enabled  = false

  tags = merge(
    { Project = var.deployment_name },
    var.azure_additional_tags
  )
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
  storage_mb             = var.postgresql_storage_mb
  sku_name               = var.postgresql_sku_name

  # Disable public network access when using VNet integration
  public_network_access_enabled = false

  backup_retention_days        = 7
  geo_redundant_backup_enabled = false
  auto_grow_enabled            = true

  maintenance_window {
    day_of_week  = 0
    start_hour   = 8
    start_minute = 0
  }

  tags = merge(
    { Project = var.deployment_name },
    var.azure_additional_tags
  )

  lifecycle {
    ignore_changes = [
      zone
    ]
  }

  depends_on = [
    azurerm_private_dns_zone_virtual_network_link.postgresql
  ]
}

# Create PostgreSQL database
resource "azurerm_postgresql_flexible_server_database" "gooddata" {
  name      = var.postgresql_database_name
  server_id = azurerm_postgresql_flexible_server.main.id
  collation = "en_US.utf8"
  charset   = "utf8"
}

resource "azurerm_postgresql_flexible_server_configuration" "trigram" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = "PG_TRGM"
}
