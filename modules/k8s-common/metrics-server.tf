###
# Deploy metrics-server to Kubernetes
###

resource "kubernetes_namespace" "metrics-server" {
  count = var.deploy_metrics_server ? 1 : 0

  metadata {
    name = "metrics-server"
  }
}

resource "helm_release" "metrics-server" {
  count = var.deploy_metrics_server ? 1 : 0

  name       = "metrics-server"
  namespace  = kubernetes_namespace.metrics-server[0].metadata[0].name
  chart      = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  version    = var.helm_metrics_server_version
  values = [<<EOF
image:
  repository: ${var.registry_k8sio}/metrics-server/metrics-server
  EOF
  ]
}
