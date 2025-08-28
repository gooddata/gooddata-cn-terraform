variable "deployment_name" { type = string }
variable "azure_location" { type = string }

variable "registry_k8sio" { type = string }

variable "helm_cluster_autoscaler_version" { type = string }

variable "resource_group_name" { type = string }
variable "aks_cluster_name" { type = string }
variable "aks_node_resource_group" { type = string }
variable "azure_subscription_id" { type = string }
variable "azure_tenant_id" { type = string }

variable "deploy_cluster_autoscaler" {
  description = "Whether to deploy the cluster autoscaler"
  type        = bool
  default     = true
}

variable "helm_ingress_nginx_version" {
  description = "Version of the ingress-nginx Helm chart to deploy"
  type        = string
}

variable "aks_kubelet_identity_client_id" {
  description = "Client ID of the AKS kubelet managed identity"
  type        = string
}

variable "aks_kubelet_identity_object_id" {
  description = "Object ID of the AKS kubelet managed identity"
  type        = string
}
