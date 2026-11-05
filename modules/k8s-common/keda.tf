###
# Deploy KEDA for GoodData.CN autoscaling
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

  values = [
    templatefile("${path.module}/templates/keda-uninstall-cleanup.yaml.tftpl", {
      namespace = kubernetes_namespace_v1.keda[0].metadata[0].name
    }),
  ]
}
