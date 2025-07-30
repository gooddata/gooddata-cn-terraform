variable "deployment_name" { type = string }
variable "gdcn_license_key" { type = string }
variable "letsencrypt_email" { type = string }

variable "cache_dockerio" { type = string }
variable "cache_quayio" { type = string }
variable "cache_registryk8sio" { type = string }

variable "helm_cert_manager_version" { type = string }
variable "helm_metrics_server_version" { type = string }
variable "helm_gdcn_version" { type = string }
variable "helm_pulsar_version" { type = string }

variable "ingress_ip" { type = string }
variable "db_hostname" { type = string }
variable "db_username" { type = string }
variable "db_password" { type = string }
variable "wildcard_dns_provider" { type = string }
