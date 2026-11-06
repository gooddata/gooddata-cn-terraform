###
# All AWS sizing per size_profile. Managed infra (RDS, EKS system nodes,
# Karpenter vCPU bounds, ingress replicas) is defined inline; GoodData.CN,
# Pulsar and observability sizing is referenced by name. AI Lake has its own
# tier, var.ai_lake_size_profile. Any managed value can be
# overridden by the matching var.* input.
###

locals {
  size_profiles = {
    dev = {
      rds = {
        instance_class    = "db.t4g.medium"
        allocated_storage = 20
      }
      system_node_type     = "m6a.xlarge"
      system_node_count    = 1
      node_cpu_limit       = 48
      node_cpu_max         = 8
      ingress_replicas     = 1
      storage_class        = "gp3"
      fast_storage_class   = "gp3"
      etcd_dedicated_nodes = false
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
      system_node_type     = "m8a.xlarge"
      system_node_count    = 2
      node_cpu_limit       = 96
      node_cpu_max         = 8
      ingress_replicas     = 2
      storage_class        = "gp3-perf"
      fast_storage_class   = "gp3-perf"
      etcd_dedicated_nodes = false
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
        # r6g.xlarge reached 55 % CPU at ~1,800 metadata gRPC/s (load test 2026-10-20).
        # 4xlarge (load test 2026-10-23): 2xlarge reached 72-79 % CPU at 420-476 DRPS and 94 % with
        # 400 DRPS plus ~0.75 visual exports/s (each export render calls metadata-api).
        instance_class    = "db.r6g.4xlarge"
        allocated_storage = 100
      }
      system_node_type  = "m8a.xlarge"
      system_node_count = 3
      # 480 (load test 2026-10-23): 400 DRPS plus 0.9 visual exports/s needs more than 320 vCPU
      # of general nodes; at 320 export-builder and result-cache pods stayed Pending.
      node_cpu_limit       = 480
      node_cpu_max         = 16
      ingress_replicas     = 3
      storage_class        = "gp3-perf"
      fast_storage_class   = "gp3-etcd"
      etcd_dedicated_nodes = true
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
        # Not smaller than prod-large, which runs the same GoodData.CN profile.
        instance_class    = "db.r6g.4xlarge"
        allocated_storage = 200
      }
      system_node_type     = "m8a.xlarge"
      system_node_count    = 3
      node_cpu_limit       = 480
      node_cpu_max         = 16
      ingress_replicas     = 3
      storage_class        = "gp3-perf"
      fast_storage_class   = "gp3-etcd"
      etcd_dedicated_nodes = true
      postgres = {
        work_mem_mb             = 64
        maintenance_work_mem_mb = 1024
      }
      # There is no prod-xl workload spec, so prod-xl reuses prod-large.
      gdcn_size          = "prod-large"
      pulsar_size        = "prod-large"
      observability_size = "prod-large"
    }
  }

  # Keyed by var.ai_lake_size_profile, which is chosen independently of
  # size_profile. Only dev/prod-small/prod-xl exist; prod-large has no tier.
  ai_lake_node_type_presets = {
    dev        = ["r8a.large", "m8a.xlarge"]
    prod-small = ["r8a.large", "r8a.xlarge"]
    prod-xl    = ["r8a.large", "r8a.8xlarge"]
  }

  profile = local.size_profiles[var.size_profile]

  # Resolved values: profile default unless the matching var.* is set.
  rds_instance_class    = coalesce(var.rds_instance_class, local.profile.rds.instance_class)
  rds_allocated_storage = coalesce(var.rds_allocated_storage, local.profile.rds.allocated_storage)
  # Prod keeps deletion protection, a final snapshot on destroy, and 14 days of
  # point-in-time recovery; dev is disposable and keeps 7 days.
  rds_is_prod                 = startswith(var.size_profile, "prod")
  rds_deletion_protection     = var.rds_deletion_protection != null ? var.rds_deletion_protection : local.rds_is_prod
  rds_skip_final_snapshot     = var.rds_skip_final_snapshot != null ? var.rds_skip_final_snapshot : !local.rds_is_prod
  rds_backup_retention_period = coalesce(var.rds_backup_retention_period, local.rds_is_prod ? 14 : 7)
  # Instance type and count of the system node group; not user-configurable.
  # Karpenter sizes the workload nodes, using the vCPU bounds below.
  system_node_type  = local.profile.system_node_type
  system_node_count = local.profile.system_node_count
  # Ceiling on total workload vCPUs Karpenter may run (NodePool spec.limits.cpu).
  eks_node_cpu_limit = coalesce(var.eks_node_cpu_limit, local.profile.node_cpu_limit)
  # Largest workload node Karpenter may pick, in vCPUs (NodePool instance-cpu Lt).
  # The m*a types it selects from have no member below 2 vCPU, so no floor is set.
  eks_node_cpu_max = coalesce(var.eks_node_cpu_max, local.profile.node_cpu_max)
  # StorageClass for GoodData.CN chart PVCs. Overridable via var.eks_storage_class.
  storage_class = coalesce(var.eks_storage_class, local.profile.storage_class)
  # Class for latency-sensitive PVCs, etcd only for now. gp3-perf differs from the
  # default class by throughput, at an IOPS level valid for any volume size.
  # gp3-etcd (prod-large, prod-xl) sets 10000 IOPS, which needs a volume of at
  # least 20 GiB; the prod-large profile sizes the etcd PVCs at 30 GiB. The etcd
  # volumeClaimTemplate is immutable: an existing install that changes this class must
  # recreate the etcd StatefulSet (see the etcd persistence comment in the profile).
  fast_storage_class = local.profile.fast_storage_class
  # Run etcd on its own Karpenter NodePool (karpenter.tf). Must match the
  # customEtcd nodeSelector of the GoodData.CN size profile.
  etcd_dedicated_nodes = local.profile.etcd_dedicated_nodes

  # AI Lake node types come from var.ai_lake_size_profile, not size_profile.
  # Empty unless AI Lake is enabled, since nothing consumes them otherwise.
  eks_ai_lake_node_types = var.enable_ai_lake ? coalesce(var.eks_ai_lake_node_types, local.ai_lake_node_type_presets[var.ai_lake_size_profile]) : []
}
