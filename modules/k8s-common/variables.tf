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
