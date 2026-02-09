variable "auth_hostname" { type = string }

variable "aws_region" {
  type    = string
  default = ""
}

variable "azure_datasource_fs_container" {
  type    = string
  default = ""
}

variable "azure_exports_container" {
  type    = string
  default = ""
}

variable "azure_quiver_container" {
  type    = string
  default = ""
}

variable "azure_storage_account_name" {
  type    = string
  default = ""
}

variable "azure_uami_client_id" {
  type    = string
  default = ""
}

variable "cloud" { type = string }

variable "db_hostname" { type = string }

variable "db_password" { type = string }

variable "db_username" { type = string }

variable "deployment_name" { type = string }

variable "gdcn_namespace" {
  type    = string
  default = "gooddata-cn"
}

variable "dex_ingress_annotations_override" {
  type    = map(string)
  default = {}
}

variable "enable_ai_features" { type = bool }

variable "enable_image_cache" { type = bool }

variable "gdcn_irsa_role_arn" {
  type    = string
  default = ""
}

variable "gdcn_license_key" { type = string }

variable "gdcn_orgs" {
  type = list(object({
    admin_group = string
    admin_user  = string
    hostname    = string
    id          = string
    name        = string
  }))
}

variable "helm_cert_manager_version" { type = string }

variable "helm_gdcn_version" { type = string }

variable "helm_ingress_nginx_version" { type = string }

variable "helm_istio_version" { type = string }

variable "helm_pulsar_version" { type = string }

variable "ingress_annotations_override" {
  type    = map(string)
  default = {}
}

variable "ingress_controller" { type = string }

variable "ingress_nginx_behind_l7" { type = bool }

variable "letsencrypt_email" { type = string }

variable "registry_dockerio" { type = string }

variable "registry_k8sio" { type = string }

variable "registry_quayio" { type = string }

variable "s3_datasource_fs_bucket_id" {
  type    = string
  default = ""
}

variable "s3_exports_bucket_id" {
  type    = string
  default = ""
}

variable "s3_quiver_cache_bucket_id" {
  type    = string
  default = ""
}

variable "local_s3_endpoint_override" {
  description = "S3 endpoint override URL (with scheme) for local S3-compatible storage (e.g. MinIO)."
  type        = string
  default     = ""
}

variable "local_s3_region" {
  description = "S3 region value for local S3-compatible storage."
  type        = string
  default     = ""
}

variable "local_s3_access_key" {
  description = "S3 access key for local S3-compatible storage."
  type        = string
  default     = ""
  sensitive   = true
}

variable "local_s3_secret_key" {
  description = "S3 secret key for local S3-compatible storage."
  type        = string
  default     = ""
  sensitive   = true
}

variable "local_s3_exports_bucket" {
  description = "Bucket name used for exports in local S3-compatible storage."
  type        = string
  default     = ""
}

variable "local_s3_datasource_fs_bucket" {
  description = "Bucket name used for Quiver datasource FS (CSV uploads) in local S3-compatible storage."
  type        = string
  default     = ""
}

variable "local_s3_quiver_cache_bucket" {
  description = "Bucket name used for Quiver durable cache in local S3-compatible storage."
  type        = string
  default     = ""
}

variable "size_profile" { type = string }

variable "tls_mode" { type = string }
