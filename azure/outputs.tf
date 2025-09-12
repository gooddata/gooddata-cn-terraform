output "azure_subscription_id" { value = var.azure_subscription_id }
output "azure_tenant_id" { value = var.azure_tenant_id }
output "azure_location" { value = var.azure_location }

# Azure Storage information for test scripts
output "azure_storage_account_name" {
  description = "Azure Storage Account name for GoodData.CN"
  value       = azurerm_storage_account.main.name
}

output "azure_resource_group_name" {
  description = "Azure Resource Group name"
  value       = azurerm_resource_group.main.name
}

# Outbound IP for datasource connectivity
output "aks_outbound_ip" {
  description = "Outbound IP address for AKS cluster - whitelist this IP in your datasources"
  value       = azurerm_public_ip.aks_outbound.ip_address
}

# Datasource whitelist instructions
output "datasource_whitelist_note" {
  description = "Important note about datasource connectivity"
  value       = <<-EOT
    ⚠️  DATASOURCE WHITELIST REQUIRED ⚠️
    
    Add this IP to your datasource firewall allowlist:
    ${azurerm_public_ip.aks_outbound.ip_address}
    
    This is the outbound IP that GoodData.CN will use to connect to your databases.
    Without whitelisting this IP, datasource connections will fail.
    EOT
}
