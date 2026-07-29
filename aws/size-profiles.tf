###
# Single source of truth for AWS sizing per size_profile: managed infra (RDS,
# EKS nodes, Karpenter node CPU ceiling, ingress replicas) inline, plus workload
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
      system_node_type = "m6a.xlarge"
      node_cpu_limit   = 48
      node_cpu_max     = 8
      ingress_replicas = 1
      storage_class    = "gp3"
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
      system_node_type = "m8a.xlarge"
      node_cpu_limit   = 96
      node_cpu_max     = 8
      ingress_replicas = 2
      storage_class    = "gp3-perf"
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
      system_node_type = "m8a.xlarge"
      node_cpu_limit   = 320
      node_cpu_max     = 16
      ingress_replicas = 3
      storage_class    = "gp3-perf"
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
      system_node_type = "m8a.xlarge"
      node_cpu_limit   = 480
      node_cpu_max     = 16
      ingress_replicas = 3
      storage_class    = "gp3-perf"
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

  # StarRocks node pools are a separate dimension from size_profile: they are
  # selected by var.starrocks_size_profile (dev/prod-small/prod-xl), which is
  # decoupled from size_profile, so they live in their own map keyed only by the
  # valid StarRocks tiers. There is intentionally no prod-large entry.
  starrocks_node_type_presets = {
    dev        = ["r8a.large", "m8a.xlarge"]
    prod-small = ["r8a.large", "r8a.xlarge"]
    prod-xl    = ["r8a.large", "r8a.8xlarge"]
  }

  profile = local.size_profiles[var.size_profile]

  # Resolved size_profile values (profile default, overridable via var.*).
  rds_instance_class    = coalesce(var.rds_instance_class, local.profile.rds.instance_class)
  rds_allocated_storage = coalesce(var.rds_allocated_storage, local.profile.rds.allocated_storage)
  # System node group instance type (not user-configurable). Workload nodes are
  # sized by Karpenter (instance-category + CPU bounds below).
  system_node_type = local.profile.system_node_type
  # Total workload vCPU ceiling (NodePool spec.limits.cpu).
  eks_node_cpu_limit = coalesce(var.eks_node_cpu_limit, local.profile.node_cpu_limit)
  # Per-node vCPU cap for workload nodes (NodePool instance-cpu Lt) within the m category.
  eks_node_cpu_max = coalesce(var.eks_node_cpu_max, local.profile.node_cpu_max)
  # StorageClass for GoodData.CN chart PVCs (gp3 for dev, gp3-perf for prod).
  # Overridable via var.eks_storage_class.
  storage_class = coalesce(var.eks_storage_class, local.profile.storage_class)

  # StarRocks node pool: indexed by the explicit var.starrocks_size_profile, NOT
  # size_profile (the two are decoupled). Only used when enable_ai_lake is true,
  # which the variable's validation requires.
  eks_starrocks_node_types = var.enable_ai_lake ? coalesce(var.eks_starrocks_node_types, local.starrocks_node_type_presets[var.starrocks_size_profile]) : []
}
