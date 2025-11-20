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

variable "azure_ingress_pip_name" {
  type    = string
  default = ""
}

variable "azure_quiver_container" {
  type    = string
  default = ""
}

variable "azure_resource_group_name" {
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

variable "base_domain" {
  type    = string
  default = ""
}

variable "cloud" { type = string }

variable "db_hostname" { type = string }

variable "db_password" { type = string }

variable "db_username" { type = string }

variable "deployment_name" { type = string }

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

variable "gdcn_org_ids" { type = list(string) }

variable "gdcn_replica_count" { type = number }

variable "helm_cert_manager_version" { type = string }

variable "helm_gdcn_version" { type = string }

variable "helm_ingress_nginx_version" { type = string }

variable "helm_pulsar_version" { type = string }

variable "ingress_annotations_override" {
  type    = map(string)
  default = {}
}

variable "ingress_class_name_override" {
  type    = string
  default = ""
}

variable "ingress_controller" { type = string }

variable "ingress_eip_allocations" {
  type    = string
  default = ""
}

variable "ingress_ip" { type = string }

variable "ingress_nginx_replica_count" { type = number }

variable "letsencrypt_email" { type = string }

variable "smtp_enabled" {
  type    = bool
  default = false
}

variable "smtp_host" {
  type    = string
  default = ""
}

variable "smtp_username" {
  type    = string
  default = ""
}

variable "smtp_password" {
  type    = string
  default = ""
}

variable "pulsar_bookkeeper_replica_count" { type = number }

variable "pulsar_broker_replica_count" { type = number }

variable "pulsar_zookeeper_replica_count" { type = number }

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

variable "wildcard_dns_provider" { type = string }
