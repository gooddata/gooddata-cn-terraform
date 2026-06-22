###
# Single source of truth for AWS sizing per size_profile: managed infra (RDS,
# EKS nodes, autoscaler ceiling, ingress replicas) inline, plus workload
# (GoodData.CN/Pulsar/observability) sizing referenced by name. StarRocks (AI
# Lake) is sized separately via var.starrocks_size_profile. Override any managed
# value via the matching var.* input.
###

locals {
  size_profiles = {
    dev = {
      rds = {
        instance_class    = "db.t4g.medium"
        allocated_storage = 20
      }
      eks_node_types       = ["m6a.xlarge", "m6a.2xlarge"]
      starrocks_node_types = ["r8a.large", "m8a.xlarge"]
      eks_max_nodes        = 6
      ingress_replicas     = 1
      postgres = {
        work_mem_mb             = 8
        maintenance_work_mem_mb = 128
      }
      gdcn_size          = "dev"
      pulsar_size        = "dev"
      observability_size = "dev"
    }
    prod-small = {
      rds = {
        instance_class    = "db.r6g.large"
        allocated_storage = 100
      }
      eks_node_types       = ["m8a.xlarge", "m8a.2xlarge"]
      starrocks_node_types = ["r8a.large", "r8a.xlarge"]
      eks_max_nodes        = 12
      ingress_replicas     = 2
      postgres = {
        work_mem_mb             = 16
        maintenance_work_mem_mb = 256
      }
      gdcn_size          = "prod-small"
      pulsar_size        = "prod-small"
      observability_size = "prod-small"
    }
    prod-large = {
      rds = {
        instance_class    = "db.r6g.xlarge"
        allocated_storage = 100
      }
      eks_node_types = ["m8a.xlarge", "m8a.2xlarge", "m8a.4xlarge"]
      # Unused: StarRocks has no prod-large tier (starrocks_size_profile can only
      # be dev/prod-small/prod-xl), so this is never selected. Present for type
      # consistency across the map.
      starrocks_node_types = ["r8a.large", "r8a.8xlarge"]
      eks_max_nodes        = 20
      ingress_replicas     = 3
      postgres = {
        work_mem_mb             = 32
        maintenance_work_mem_mb = 512
      }
      gdcn_size          = "prod-large"
      pulsar_size        = "prod-large"
      observability_size = "prod-large"
    }
    prod-xl = {
      rds = {
        instance_class    = "db.r6g.2xlarge"
        allocated_storage = 200
      }
      eks_node_types       = ["m8a.xlarge", "m8a.2xlarge", "m8a.4xlarge"]
      starrocks_node_types = ["r8a.large", "r8a.8xlarge"]
      eks_max_nodes        = 30
      ingress_replicas     = 3
      postgres = {
        work_mem_mb             = 64
        maintenance_work_mem_mb = 1024
      }
      # No prod-xl GDCN/Pulsar/observability spec; fold to prod-large (explicit).
      gdcn_size          = "prod-large"
      pulsar_size        = "prod-large"
      observability_size = "prod-large"
    }
  }

  profile = local.size_profiles[var.size_profile]

  # Resolved size_profile values (profile default, overridable via var.*).
  rds_instance_class    = coalesce(var.rds_instance_class, local.profile.rds.instance_class)
  rds_allocated_storage = coalesce(var.rds_allocated_storage, local.profile.rds.allocated_storage)
  eks_node_types        = coalesce(var.eks_node_types, local.profile.eks_node_types)
  eks_max_nodes         = coalesce(var.eks_max_nodes, local.profile.eks_max_nodes)

  # StarRocks node pool: indexed by the explicit var.starrocks_size_profile, NOT
  # size_profile (the two are decoupled). Only used when enable_ai_lake is true,
  # which the variable's validation requires.
  eks_starrocks_node_types = var.enable_ai_lake ? coalesce(var.eks_starrocks_node_types, local.size_profiles[var.starrocks_size_profile].starrocks_node_types) : []
}
