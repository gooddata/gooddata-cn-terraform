###
# Docker Hardened Images (DHI): registry, Helm login and image pull secrets
###

locals {
  dhi_registry         = "dhi.io"
  dhi_pull_secret_name = "dhi-pull-secret" # the default of modules/dhi-pull-secret

  dhi_pull_namespaces = merge(
    {
      lb_controller  = kubernetes_namespace_v1.alb.metadata[0].name
      metrics_server = kubernetes_namespace_v1.metrics-server.metadata[0].name
    },
    local.external_dns_enabled ? { external_dns = kubernetes_namespace_v1.external_dns[0].metadata[0].name } : {},
  )
}

module "dhi_pull" {
  source = "../dhi-pull-secret"

  username     = var.dhi_username
  access_token = var.dhi_access_token
  namespaces   = local.dhi_pull_namespaces
  consumers    = "platform components are"
}
