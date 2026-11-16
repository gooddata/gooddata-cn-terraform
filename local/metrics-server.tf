###
# metrics-server from Docker Hardened Images (k3s's bundled one is disabled in k3d-config.yaml)
# The k3d registry config authenticates containerd to dhi.io, so no pull secret is needed.
###

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "oci://dhi.io"
  chart      = "metrics-server-chart"
  namespace  = "kube-system"
  version    = var.helm_metrics_server_version

  repository_username = var.dockerhub_username
  repository_password = var.dockerhub_access_token

  wait    = true
  timeout = 300

  depends_on = [null_resource.k3d_cluster]
}
