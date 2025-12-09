###
# Provision Azure Resource Group
###

resource "azurerm_resource_group" "main" {
  name     = "${var.deployment_name}-rg"
  location = var.azure_location

  tags = local.common_tags
}
