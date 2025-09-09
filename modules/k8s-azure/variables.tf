variable "deployment_name" { type = string }

variable "registry_k8sio" { type = string }

variable "resource_group_name" { type = string }

variable "helm_ingress_nginx_version" {
  description = "Version of the ingress-nginx Helm chart to deploy"
  type        = string
}
