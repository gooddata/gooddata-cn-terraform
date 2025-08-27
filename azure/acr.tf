###
# Provision Azure Container Registry with caching for Docker Hub
###

# If image caching is enabled, construct the registry URL. Otherwise, return the upstream one.
locals {
  upstream_registry_dockerio = "registry-1.docker.io"
  registry_dockerio = var.acr_cache_images ? "${azurerm_container_registry.main[0].login_server}/dockerio" : local.upstream_registry_dockerio

  upstream_registry_quayio = "quay.io"
  registry_quayio = var.acr_cache_images ? "${azurerm_container_registry.main[0].login_server}/quayio" : local.upstream_registry_quayio

  upstream_registry_k8sio = "registry.k8s.io"
  registry_k8sio = var.acr_cache_images ? "${azurerm_container_registry.main[0].login_server}/k8sio" : local.upstream_registry_k8sio
}

# Ensure the name is lower-case and contains no spaces or invalid chars
resource "random_id" "acr_suffix" {
  count = var.acr_cache_images ? 1 : 0

  byte_length = 3
}

locals {
  # Sanitize deployment name and append a random 6-character
  # suffix for ACR name to make it globally unique
  acr_name = var.acr_cache_images ? substr(
    replace(
      "${replace(lower(var.deployment_name), "[^0-9a-z]", "")}${random_id.acr_suffix[0].hex}",
      "-", ""
    ),
    0, 50
  ) : ""
}

resource "azurerm_container_registry" "main" {
  count = var.acr_cache_images ? 1 : 0

  name                = local.acr_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Premium"
  admin_enabled       = false

  # Enable georeplications for better performance (optional)
  georeplications {
    location                = "West US"
    zone_redundancy_enabled = false
    tags                    = {}
  }

  # Network access
  public_network_access_enabled = true
  network_rule_set {
    default_action = "Allow"
  }

  tags = merge(
    { Project = var.deployment_name },
    var.azure_additional_tags
  )
}

# Create cache rules for Docker Hub
resource "azurerm_container_registry_cache_rule" "dockerio" {
  count = var.acr_cache_images ? 1 : 0

  name                 = "dockerio"
  container_registry_id = azurerm_container_registry.main[0].id
  target_repo          = "dockerio/*"
  source_repo          = "${local.upstream_registry_dockerio}/*"
  credential_set_id    = azurerm_container_registry_credential_set.dockerio[0].id
}

# Create cache rules for Quay.io
resource "azurerm_container_registry_cache_rule" "quayio" {
  count = var.acr_cache_images ? 1 : 0

  name                 = "quayio"
  container_registry_id = azurerm_container_registry.main[0].id
  target_repo          = "quayio/*"
  source_repo          = "${local.upstream_registry_quayio}/*"
}

# Create cache rules for k8s.io
resource "azurerm_container_registry_cache_rule" "k8sio" {
  count = var.acr_cache_images ? 1 : 0

  name                 = "k8sio"
  container_registry_id = azurerm_container_registry.main[0].id
  target_repo          = "k8sio/*"
  source_repo          = "${local.upstream_registry_k8sio}/*"
}

# Validation: Ensure Docker Hub credentials are provided when ACR caching is enabled
locals {
  validate_dockerhub_credentials = var.acr_cache_images && (var.dockerhub_username == "" || var.dockerhub_access_token == "") ? tobool("Error: dockerhub_username and dockerhub_access_token must be provided when acr_cache_images is true") : true
}

# Store Docker Hub credentials in Key Vault
resource "azurerm_key_vault" "main" {
  count = var.acr_cache_images ? 1 : 0

  name                = "${var.deployment_name}-kv-${random_id.acr_suffix[0].hex}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id

    key_permissions = [
      "Get", "List", "Create", "Delete", "Update", "Purge", "Recover"
    ]

    secret_permissions = [
      "Get", "List", "Set", "Delete", "Purge", "Recover"
    ]
  }

  tags = merge(
    { Project = var.deployment_name },
    var.azure_additional_tags
  )
}

# Store Docker Hub username
resource "azurerm_key_vault_secret" "dockerhub_username" {
  count = var.acr_cache_images ? 1 : 0

  name         = "dockerhub-username"
  value        = var.dockerhub_username
  key_vault_id = azurerm_key_vault.main[0].id
}

# Store Docker Hub access token
resource "azurerm_key_vault_secret" "dockerhub_token" {
  count = var.acr_cache_images ? 1 : 0

  name         = "dockerhub-token"
  value        = var.dockerhub_access_token
  key_vault_id = azurerm_key_vault.main[0].id
}

# Create credential set for Docker Hub
resource "azurerm_container_registry_credential_set" "dockerio" {
  count = var.acr_cache_images ? 1 : 0

  name                  = "dockerio-credentials"
  container_registry_id = azurerm_container_registry.main[0].id
  login_server          = local.upstream_registry_dockerio

  identity {
    type = "SystemAssigned"
  }

  authentication_credentials {
    username_secret_id = azurerm_key_vault_secret.dockerhub_username[0].id
    password_secret_id = azurerm_key_vault_secret.dockerhub_token[0].id
  }
}
