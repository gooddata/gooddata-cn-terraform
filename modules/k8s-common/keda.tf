###
# Deploy KEDA (and metrics-server where needed) for GoodData.CN autoscaling
###

resource "kubernetes_namespace_v1" "keda" {
  count = var.enable_gdcn_autoscaling ? 1 : 0

  metadata {
    name = "keda"
  }
}

resource "helm_release" "keda" {
  count = var.enable_gdcn_autoscaling ? 1 : 0

  name       = "keda"
  repository = "https://kedacore.github.io/charts"
  chart      = "keda"
  version    = var.helm_keda_version
  namespace  = kubernetes_namespace_v1.keda[0].metadata[0].name
}

# The CPU trigger needs Metrics Server. AKS and k3d ship it; EKS does not.
resource "helm_release" "metrics_server" {
  count = var.enable_gdcn_autoscaling && var.cloud == "aws" ? 1 : 0

  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = var.helm_metrics_server_version
  namespace  = "kube-system"
}
