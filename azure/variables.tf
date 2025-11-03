variable "azure_subscription_id" {
  description = "Azure subscription ID to deploy resources to."
  type        = string
}

variable "azure_tenant_id" {
  description = "Azure tenant ID for authentication."
  type        = string
}

variable "azure_location" {
  description = "Azure location to deploy resources to."
  type        = string
  default     = "East US"
}

variable "azure_additional_tags" {
  description = "Map of additional tags to apply to all Azure resources"
  type        = map(string)
  default     = {}
}

variable "deployment_name" {
  description = "Name prefix for all Azure resources."
  type        = string
  default     = "gooddata-cn"

  validation {
    condition     = can(regex("^[a-z0-9-]{1,50}$", var.deployment_name)) && length(join("", regexall("[0-9a-z]", lower(var.deployment_name)))) <= 18
    error_message = "The deployment_name must contain only lowercase letters, numbers, and hyphens. After removing non-alphanumeric characters, it must be ≤18 characters to allow space for 6-character random suffix."
  }
}

variable "dockerhub_username" {
  description = "Docker Hub username (used to pull images without hitting rate limits). Free account is enough."
  type        = string
  default     = ""
  validation {
    condition     = var.acr_cache_images ? length(var.dockerhub_username) > 0 : true
    error_message = "dockerhub_username must be provided when acr_cache_images is true."
  }
}

variable "dockerhub_access_token" {
  description = "Docker Hub access token (can be created in Settings > Personal Access Tokens)"
  type        = string
  default     = ""
  sensitive   = true
  validation {
    condition     = var.acr_cache_images ? length(var.dockerhub_access_token) > 0 : true
    error_message = "dockerhub_access_token must be provided when acr_cache_images is true."
  }
}

variable "acr_cache_images" {
  description = "If true, ACR cache rules will be created and all services configured to use it. If false, images are pulled from their original registries."
  type        = bool
  default     = false
}

variable "aks_version" {
  description = "Version of AKS to deploy."
  type        = string
  default     = "1.33"
}

variable "aks_node_vm_size" {
  description = "VM size for AKS worker nodes. E.g. Standard_D4as_v6, Standard_D4pd_v6"
  type        = string
  default     = "Standard_D4as_v6"
}

variable "aks_max_nodes" {
  description = "Maximum number of AKS worker nodes"
  type        = number
  default     = 10
}

variable "aks_enable_auto_scaling" {
  description = "Enable AKS built-in cluster autoscaler for the default node pool"
  type        = bool
  default     = true
}


variable "aks_min_nodes" {
  description = "Minimum number of AKS worker nodes"
  type        = number
  default     = 2
}

variable "postgresql_sku_name" {
  description = "Azure Database for PostgreSQL SKU name. E.g. B_Standard_B1ms, GP_Standard_D2s_v3, MO_Standard_E4s_v3"
  type        = string
  default     = "GP_Standard_D2ds_v5"
}

variable "postgresql_storage_mb" {
  description = "Azure Database for PostgreSQL storage in MB"
  type        = number
  default     = 32768
}

variable "postgresql_database_name" {
  description = "Name of the PostgreSQL database for GoodData.CN metadata"
  type        = string
  default     = "gooddata"
}

variable "gdcn_license_key" {
  description = "GoodData.CN license key (provided by your GoodData contact)"
  type        = string
  sensitive   = true
}

variable "gdcn_replica_count" {
  description = "Replica count for GoodData.CN components (passed to the chart)."
  type        = number
  default     = 1
}

variable "letsencrypt_email" {
  description = "Email address used for Let's Encrypt ACME registration"
  type        = string
}

variable "wildcard_dns_provider" {
  description = "Wildcard DNS service used to give a dynamic hostname for hosting GoodData.CN. [default: sslip.io]"
  type        = string
  default     = "sslip.io"
}

variable "helm_cert_manager_version" {
  description = "Version of the cert-manager Helm chart to deploy. https://artifacthub.io/packages/helm/cert-manager/cert-manager"
  type        = string
  default     = "v1.18.2"
}

variable "helm_metrics_server_version" {
  description = "Version of the metrics-server Helm chart to deploy. https://artifacthub.io/packages/helm/metrics-server/metrics-server"
  type        = string
  default     = "3.13.0"
}

variable "helm_gdcn_version" {
  description = "Version of the gooddata-cn Helm chart to deploy. https://artifacthub.io/packages/helm/gooddata-cn/gooddata-cn"
  type        = string
}

variable "helm_pulsar_version" {
  description = "Version of the pulsar Helm chart to deploy. https://artifacthub.io/packages/helm/apache/pulsar"
  type        = string
  default     = "3.9.0"
}

variable "helm_ingress_nginx_version" {
  description = "Version of the ingress-nginx Helm chart to deploy. https://artifacthub.io/packages/helm/ingress-nginx/ingress-nginx"
  type        = string
  default     = "4.11.3"
}
