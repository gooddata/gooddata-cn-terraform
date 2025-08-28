###
# Deploy all Azure-specific Kubernetes resources
###

module "k8s_azure" {
  source = "../modules/k8s-azure"

  providers = {
    kubernetes = kubernetes
    helm       = helm
  }

  deployment_name = var.deployment_name
  azure_location  = var.azure_location

  registry_k8sio = local.registry_k8sio

  helm_cluster_autoscaler_version = var.helm_cluster_autoscaler_version
  helm_ingress_nginx_version      = var.helm_ingress_nginx_version

  resource_group_name            = azurerm_resource_group.main.name
  aks_cluster_name               = azurerm_kubernetes_cluster.main.name
  aks_node_resource_group        = azurerm_kubernetes_cluster.main.node_resource_group
  azure_subscription_id          = data.azurerm_client_config.current.subscription_id
  azure_tenant_id                = data.azurerm_client_config.current.tenant_id
  aks_kubelet_identity_client_id = azurerm_kubernetes_cluster.main.kubelet_identity[0].client_id
  aks_kubelet_identity_object_id = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
  deploy_cluster_autoscaler      = var.deploy_cluster_autoscaler

  depends_on = [
    azurerm_kubernetes_cluster.main,
    azurerm_container_registry_cache_rule.k8sio
  ]
}

output "ingress_external_ip" {
  description = "External IP address of the nginx ingress LoadBalancer"
  value       = module.k8s_azure.ingress_external_ip
}
