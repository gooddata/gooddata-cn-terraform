variable "db_password" {
  description = "PostgreSQL superuser password for the in-cluster (CloudNativePG) database."
  type        = string
  sensitive   = true
}

variable "db_username" {
  description = "PostgreSQL superuser username for the in-cluster (CloudNativePG) database."
  type        = string
}

variable "enable_istio_injection" {
  description = "Whether to label namespaces with istio-injection=enabled."
  type        = bool
  default     = false
}

variable "enable_observability" {
  description = "Whether observability (Prometheus, Grafana, etc.) is enabled. Controls PodMonitor creation for CNPG and PostgreSQL."
  type        = bool
  default     = false
}

variable "helm_cnpg_version" {
  description = "Version of the CloudNativePG Helm chart to deploy."
  type        = string
  # renovate: depName=cloudnative-pg registryUrl=https://cloudnative-pg.github.io/charts
  default = "0.28.0"
}

variable "helm_seaweedfs_version" {
  description = "Version of the SeaweedFS Helm chart to deploy."
  type        = string
  # renovate: depName=seaweedfs registryUrl=https://seaweedfs.github.io/seaweedfs/helm
  default = "4.17.0"
}

variable "kubeconfig_context" {
  description = "Kubeconfig context to use for provisioning."
  type        = string
}

variable "kubeconfig_path" {
  description = "Path to kubeconfig file used for provisioning."
  type        = string
}

variable "postgres_image" {
  description = "PostgreSQL container image for the CloudNativePG Cluster."
  type        = string
  default     = "ghcr.io/cloudnative-pg/postgresql:16.4"
}

variable "s3_region" {
  description = "Region value used by S3 clients. (SeaweedFS ignores this but some clients require it.)"
  type        = string
  default     = "us-east-1"
}

variable "seaweedfs_bucket_datasource_fs" {
  description = "Bucket used for Quiver datasource filesystem (CSV uploads)."
  type        = string
  default     = "gooddata-datasource-fs"
}

variable "seaweedfs_bucket_exports" {
  description = "Bucket used for exports."
  type        = string
  default     = "gooddata-exports"
}

variable "seaweedfs_bucket_quiver_cache" {
  description = "Bucket used for Quiver durable cache."
  type        = string
  default     = "gooddata-quiver-cache"
}

variable "seaweedfs_release_name" {
  description = "Helm release name for SeaweedFS."
  type        = string
  default     = "seaweedfs"
}

variable "registry_dockerio" {
  description = "Docker Hub registry prefix (e.g. docker.io or a pull-through cache)."
  type        = string
  default     = "docker.io"
}

variable "seaweedfs_storage_class" {
  description = "StorageClass name for SeaweedFS PVC. Empty uses cluster default."
  type        = string
  default     = "local-path"
}
