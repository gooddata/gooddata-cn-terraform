variable "db_password" {
  description = "PostgreSQL superuser password for the in-cluster (CloudNativePG) database."
  type        = string
  sensitive   = true
}

variable "db_username" {
  description = "PostgreSQL superuser username for the in-cluster (CloudNativePG) database."
  type        = string
}

variable "helm_cnpg_version" {
  description = "Version of the CloudNativePG Helm chart to deploy."
  type        = string
  default     = "0.27.0"
}

variable "helm_minio_version" {
  description = "Version of the official MinIO Helm chart to deploy."
  type        = string
  default     = "5.4.0"
}

variable "minio_bucket_datasource_fs" {
  description = "Bucket used for Quiver datasource filesystem (CSV uploads)."
  type        = string
  default     = "gooddata-datasource-fs"
}

variable "minio_bucket_exports" {
  description = "Bucket used for exports."
  type        = string
  default     = "gooddata-exports"
}

variable "minio_bucket_quiver_cache" {
  description = "Bucket used for Quiver durable cache."
  type        = string
  default     = "gooddata-quiver-cache"
}

variable "minio_region" {
  description = "Region value used by S3 clients. (MinIO ignores this but some clients require it.)"
  type        = string
  default     = "us-east-1"
}

variable "minio_release_name" {
  description = "Helm release name for MinIO."
  type        = string
  default     = "minio"
}

variable "minio_storage_class" {
  description = "StorageClass name for MinIO PVC. Empty uses cluster default."
  type        = string
  default     = "local-path"
}

variable "postgres_image" {
  description = "PostgreSQL container image for the CloudNativePG Cluster."
  type        = string
  default     = "ghcr.io/cloudnative-pg/postgresql:16.4"
}