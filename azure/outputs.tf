output "azure_subscription_id" { value = var.azure_subscription_id }
output "azure_tenant_id" { value = var.azure_tenant_id }
output "azure_location" { value = var.azure_location }

output "azure_resource_group_name" {
  description = "Azure Resource Group name"
  value       = azurerm_resource_group.main.name
}
