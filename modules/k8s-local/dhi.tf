###
# Docker Hardened Images (DHI): pull secret for the local data services
###

locals {
  dhi_registry         = "dhi.io"
  dhi_pull_secret_name = "dhi-pull-secret" # the default of modules/dhi-pull-secret
}

module "dhi_pull" {
  source = "../dhi-pull-secret"

  username     = var.dhi_username
  access_token = var.dhi_access_token
  namespaces = {
    cnpg      = kubernetes_namespace_v1.cnpg.metadata[0].name
    postgres  = kubernetes_namespace_v1.postgres.metadata[0].name
    seaweedfs = kubernetes_namespace_v1.seaweedfs.metadata[0].name
  }
  consumers = "CloudNativePG, PostgreSQL and SeaweedFS are"
}
