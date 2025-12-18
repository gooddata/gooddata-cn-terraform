###
# Deploy metrics-server to Kubernetes
###

resource "kubernetes_namespace" "metrics-server" {
  metadata {
    name = "metrics-server"
  }
}

resource "helm_release" "metrics-server" {
  name          = "metrics-server"
  namespace     = kubernetes_namespace.metrics-server.metadata[0].name
  chart         = "metrics-server"
  repository    = "https://kubernetes-sigs.github.io/metrics-server/"
  version       = var.helm_metrics_server_version
  wait          = true
  wait_for_jobs = true
  timeout       = 1800
  values = [<<EOF
image:
  repository: ${var.registry_k8sio}/metrics-server/metrics-server
EOF
  ]
}
