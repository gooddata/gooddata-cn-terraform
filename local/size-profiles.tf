###
# All local (k3d) sizing; "dev" is the only profile local supports. The
# in-cluster Postgres (CNPG) sizing is defined inline; GoodData.CN, Pulsar and
# observability sizing is referenced by name. AI Lake is not supported
# on local.
###

locals {
  size_profiles = {
    dev = {
      cnpg = {
        cpu                     = "200m"
        instances               = 1
        maintenance_work_mem_mb = 128
        memory                  = "256Mi"
        storage                 = "2Gi"
        work_mem_mb             = 8
      }
      ingress_replicas   = 1
      gdcn_size          = "dev"
      pulsar_size        = "dev"
      observability_size = "dev"
    }
  }

  profile = local.size_profiles[var.size_profile]
}
