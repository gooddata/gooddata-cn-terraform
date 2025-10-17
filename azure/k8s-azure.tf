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

  registry_k8sio = local.registry_k8sio

  helm_ingress_nginx_version = var.helm_ingress_nginx_version

  resource_group_name    = azurerm_resource_group.main.name
  ingress_public_ip_name = azurerm_public_ip.ingress.name

  depends_on = [
    azurerm_kubernetes_cluster.main,
    azurerm_container_registry_cache_rule.k8sio
  ]
}

