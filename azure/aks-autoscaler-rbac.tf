###
# RBAC for AKS Cluster Autoscaler
###

# Grant the AKS kubelet identity permissions to manage VMSS
resource "azurerm_role_assignment" "aks_kubelet_vmss_contributor" {
  scope                = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${azurerm_kubernetes_cluster.main.node_resource_group}"
  role_definition_name = "Virtual Machine Contributor"
  principal_id         = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
}

# Grant permissions to read VMSS information
resource "azurerm_role_assignment" "aks_kubelet_vmss_reader" {
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Reader"
  principal_id         = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
}
