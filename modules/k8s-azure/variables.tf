variable "deployment_name" { type = string }

variable "registry_k8sio" { type = string }

variable "resource_group_name" { type = string }

variable "ingress_public_ip_name" {
  description = "Name of the pre-allocated public IP for ingress"
  type        = string
}

variable "helm_ingress_nginx_version" {
  description = "Version of the ingress-nginx Helm chart to deploy"
  type        = string
}
