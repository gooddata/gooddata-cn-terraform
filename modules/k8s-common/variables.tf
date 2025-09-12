variable "deployment_name" { type = string }
variable "gdcn_license_key" { type = string }
variable "letsencrypt_email" { type = string }

variable "registry_dockerio" { type = string }
variable "registry_quayio" { type = string }
variable "registry_k8sio" { type = string }

variable "helm_cert_manager_version" { type = string }
variable "helm_metrics_server_version" { type = string }
variable "helm_gdcn_version" { type = string }
variable "helm_pulsar_version" { type = string }

variable "deploy_metrics_server" {
  type        = bool
  default     = true
  description = "Whether to deploy metrics-server (set to false for Azure)"
}

variable "ingress_ip" { type = string }
variable "db_hostname" { type = string }
variable "db_username" { type = string }
variable "db_password" { type = string }
variable "db_name" {
  type        = string
  default     = "gooddata"
  description = "Name of the database for GoodData.CN metadata"
}
variable "wildcard_dns_provider" { type = string }
variable "gdcn_replica_count" { type = number }

# Organization variables
variable "create_default_organization" {
  type        = bool
  default     = true
  description = "Whether to create a default GoodData.CN organization"
}

variable "default_org_id" {
  type        = string
  default     = "demo"
  description = "ID of the default organization"
}

variable "default_org_name" {
  type        = string
  default     = "demo-org"
  description = "Kubernetes resource name for the default organization"
}

variable "default_org_display_name" {
  type        = string
  default     = "Demo Organization"
  description = "Display name of the default organization"
}

# Azure Blob Storage variables for quiver cache
variable "azure_storage_account_name" {
  type        = string
  default     = ""
  description = "Azure Storage Account name for quiver cache (S3-compatible)"
}

variable "azure_storage_account_key" {
  type        = string
  default     = ""
  description = "Azure Storage Account key for quiver cache"
  sensitive   = true
}

variable "azure_storage_container_cache" {
  type        = string
  default     = "quiver-cache"
  description = "Azure Blob Storage container name for quiver cache"
}

variable "azure_storage_endpoint" {
  type        = string
  default     = ""
  description = "Azure Blob Storage endpoint URL"
}

variable "azure_region" {
  type        = string
  default     = ""
  description = "Azure region for storage configuration"
}
