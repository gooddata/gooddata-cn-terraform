variable "deployment_name" { type = string }
variable "gdcn_license_key" { type = string }
variable "letsencrypt_email" { type = string }
variable "registry_dockerio" { type = string }
variable "registry_quayio" { type = string }
variable "registry_k8sio" { type = string }
variable "helm_cert_manager_version" { type = string }
variable "helm_gdcn_version" { type = string }
variable "helm_pulsar_version" { type = string }
variable "helm_ingress_nginx_version" { type = string }
variable "gdcn_replica_count" { type = number }
variable "ingress_ip" { type = string }
variable "db_hostname" { type = string }
variable "db_username" { type = string }
variable "db_password" { type = string }
variable "wildcard_dns_provider" { type = string }
variable "cloud" { type = string }
variable "ingress_controller" { type = string }

variable "use_image_cache" {
  type    = bool
  default = false
}

variable "gdcn_namespace" {
  type    = string
  default = "gooddata-cn"
}

variable "gdcn_service_account_name" {
  type    = string
  default = "gooddata-cn"
}

variable "gdcn_irsa_role_arn" {
  type    = string
  default = ""
}

variable "aws_region" {
  type    = string
  default = ""
}

variable "ingress_eip_allocations" {
  type    = string
  default = ""
}

variable "s3_quiver_cache_bucket_id" {
  type    = string
  default = ""
}

variable "s3_datasource_fs_bucket_id" {
  type    = string
  default = ""
}

variable "s3_exports_bucket_id" {
  type    = string
  default = ""
}

variable "base_domain" {
  type    = string
  default = ""
}

variable "ingress_class_name_override" {
  type    = string
  default = ""
}

variable "ingress_annotations_override" {
  type    = map(string)
  default = {}
}

variable "dex_ingress_annotations_override" {
  type    = map(string)
  default = {}
}

variable "azure_storage_account_name" {
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

variable "azure_datasource_fs_container" {
  type    = string
  default = ""
}

variable "azure_resource_group_name" {
  type    = string
  default = ""
}

variable "azure_ingress_pip_name" {
  type    = string
  default = ""
}

variable "azure_uami_client_id" {
  type    = string
  default = ""
}
