###
# Deploy metrics-server to Kubernetes
###

resource "kubernetes_namespace_v1" "metrics-server" {
  metadata {
    name = "metrics-server"
  }
}

resource "helm_release" "metrics-server" {
  name          = "metrics-server"
  namespace     = kubernetes_namespace_v1.metrics-server.metadata[0].name
  chart         = "metrics-server-chart"
  repository    = "oci://${local.dhi_registry}"
  version       = var.helm_metrics_server_version
  wait          = true
  wait_for_jobs = true
  timeout       = 1800

  repository_username = var.dhi_username
  repository_password = var.dhi_access_token

  # Tolerate the system pool taint: this runs before Karpenter has provisioned
  # any untainted capacity, so the system nodes are the only place it can land.
  values = [<<EOF
imagePullSecrets:
  - name: ${local.dhi_pull_secret_name}
tolerations:
  - key: CriticalAddonsOnly
    operator: Exists
EOF
  ]

  depends_on = [module.dhi_pull]
}
