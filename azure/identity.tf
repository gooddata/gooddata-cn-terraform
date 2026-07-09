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
  name                      = "gdcn-workload"
  user_assigned_identity_id = azurerm_user_assigned_identity.gdcn.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject                   = "system:serviceaccount:${var.gdcn_namespace}:${local.gdcn_service_account_name}"
}

###
# Workload Identity for observability (Loki + Tempo) -> Blob object storage.
# One UAMI with Blob Data Contributor on the storage account, federated to the
# loki and tempo service accounts in the observability namespace. Loki/Tempo
# auth to Blob via the projected SA token (use_federated_token), no keys.
###

resource "azurerm_user_assigned_identity" "observability" {
  name                = "${var.deployment_name}-obs-uami"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  tags = local.common_tags
}

resource "azurerm_role_assignment" "observability_blob_contrib" {
  scope                = azurerm_storage_account.main.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.observability.principal_id
}

resource "azurerm_federated_identity_credential" "loki" {
  name                      = "loki-workload"
  user_assigned_identity_id = azurerm_user_assigned_identity.observability.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject                   = "system:serviceaccount:observability:loki"
}

resource "azurerm_federated_identity_credential" "tempo" {
  name                      = "tempo-workload"
  user_assigned_identity_id = azurerm_user_assigned_identity.observability.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject                   = "system:serviceaccount:observability:tempo"
}
