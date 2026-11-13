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
  repository = "oci://${local.dhi_registry}"
  chart      = "keda-chart"
  version    = var.helm_keda_version
  namespace  = kubernetes_namespace_v1.keda[0].metadata[0].name

  repository_username = var.dhi_username
  repository_password = var.dhi_access_token

  values = [
    templatefile("${path.module}/templates/keda-uninstall-cleanup.yaml.tftpl", {
      namespace   = kubernetes_namespace_v1.keda[0].metadata[0].name
      registry    = local.dhi_registry
      pull_secret = local.dhi_pull_secret_name
    }),
    yamlencode({ imagePullSecrets = [{ name = local.dhi_pull_secret_name }] }),
  ]

  depends_on = [module.dhi_pull]
}
