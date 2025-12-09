###
# Workload Identity for GoodData.CN pods (UAMI + FIC + Role Assignment)
###

resource "azurerm_user_assigned_identity" "gdcn" {
  name                = "${var.deployment_name}-gdcn-uami"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  tags = local.common_tags
}

resource "azurerm_role_assignment" "gdcn_blob_contrib" {
  scope                = azurerm_storage_account.main.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.gdcn.principal_id
}

resource "azurerm_federated_identity_credential" "gdcn" {
  name                = "gdcn-workload"
  resource_group_name = azurerm_resource_group.main.name
  parent_id           = azurerm_user_assigned_identity.gdcn.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject             = "system:serviceaccount:${local.gdcn_namespace}:${local.gdcn_service_account_name}"

  depends_on = [
    azurerm_kubernetes_cluster.main
  ]
}
