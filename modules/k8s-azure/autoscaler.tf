###
# Deploy cluster-autoscaler to Kubernetes for Azure
###

resource "kubernetes_namespace" "cluster_autoscaler" {
  count = var.deploy_cluster_autoscaler ? 1 : 0

  metadata {
    name = "cluster-autoscaler"
  }
}

# Install Cluster Autoscaler via Helm
resource "helm_release" "cluster_autoscaler" {
  count = var.deploy_cluster_autoscaler ? 1 : 0

  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = var.helm_cluster_autoscaler_version
  namespace  = kubernetes_namespace.cluster_autoscaler[0].metadata[0].name

  # Values to configure Cluster Autoscaler for Azure
  values = [<<-EOF
image:
  repository: ${var.registry_k8sio}/autoscaling/cluster-autoscaler

rbac:
  serviceAccount:
    create: true
    annotations:
      azure.workload.identity/client-id: ${var.aks_kubelet_identity_client_id}

serviceAccount:
  create: true
  name: cluster-autoscaler

cloudProvider: azure

# Azure-specific configuration
azureClusterName: ${var.aks_cluster_name}
azureResourceGroup: ${var.resource_group_name}
azureNodeResourceGroup: ${var.aks_node_resource_group}
azureSubscriptionID: ${var.azure_subscription_id}
azureTenantID: ${var.azure_tenant_id}
azureVMType: "vmss"
azureUseManagedIdentityExtension: true
azureUserAssignedIdentityID: ${var.aks_kubelet_identity_client_id}

# Azure VMSS auto-discovery (doesn't rely on tags)
autoDiscovery:
  clusterName: ${var.aks_cluster_name}

# Resource limits
resources:
  limits:
    cpu: 100m
    memory: 300Mi
  requests:
    cpu: 100m
    memory: 300Mi

nodeSelector:
  "kubernetes.io/os": linux

tolerations: []

# Scaling behavior
scaleDownDelayAfterAdd: "10m"
scaleDownDelayAfterDelete: "10s" 
scaleDownDelayAfterFailure: "3m"
scaleDownUnneededTime: "10m"
scaleDownUtilizationThreshold: 0.5
EOF
  ]

  depends_on = [
    kubernetes_namespace.cluster_autoscaler,
  ]
}
