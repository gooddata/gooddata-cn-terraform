###
# Single source of truth for local (k3d) sizing. Local supports only "dev"
# (smallest, non-HA). Holds the in-cluster postgres (CNPG) sizing inline plus
# workload (GoodData.CN/Pulsar/observability) sizing referenced by name.
# StarRocks (AI Lake) is not supported on local.
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
