###
# All STACKIT sizing per size_profile. Managed infra (PostgreSQL Flex, SKE node
# pools, ingress replicas) is defined inline; GoodData.CN, Pulsar and
# observability sizing is referenced by name. prod-xl is AWS-only. Any managed
# value can be overridden by the matching var.* input.
###

# SKE has no Karpenter provider, so workload capacity comes from a declared node
# pool with min/max bounds that SKE's cluster autoscaler scales between, rather
# than from just-in-time instance selection. machine_type is therefore the main
# sizing lever and is user-overridable, unlike the Azure system pool's VM size.

# Machine types: g = 1:4 vCPU:RAM, "2a" = AMD gen2, trailing "d" = no CPU
# overcommit. g2a is the STACKIT analogue of the AMD 4 GiB/vCPU Das_v6 fleet the
# Azure NodePool pins. Check what your region offers with:
#   stackit ske options --machine-types
#
# PostgreSQL Flex flavor IDs are vCPU.RAM with a -replica suffix for 3-node
# replication. Only 2.4, 2.16, 4.8, 4.32, 8.16, 16.32 and 16.128 exist, so the
# shapes below are the nearest available to the Azure profiles, not exact matches.
#   stackit postgresflex flavor list
locals {
  size_profiles = {
    dev = {
      postgresflex = {
        flavor_id      = "2.4"
        storage_class  = "premium-perf2-stackit"
        storage_size   = 32
        retention_days = 32
      }
      system_nodes = {
        machine_type = "g2a.4d"
        min          = 1
        max          = 2
      }
      workload_nodes = {
        machine_type = "g2a.4d"
        min          = 1
        max          = 4
      }
      storage_class      = "premium-perf1-stackit"
      fast_storage_class = ""
      ingress_replicas   = 1
      gdcn_size          = "dev"
      pulsar_size        = "dev"
      observability_size = "dev"
    }
    prod-small = {
      postgresflex = {
        # No 4 vCPU / 16 GB shape exists, so prod rounds up rather than down.
        flavor_id     = "4.32-replica"
        storage_class = "premium-perf2-stackit"
        storage_size  = 128
        # STACKIT only accepts 32-90 days, so its floor already exceeds the 14
        # days prod keeps on Azure. Prod takes the full window.
        retention_days = 90
      }
      system_nodes = {
        machine_type = "g2a.4d"
        min          = 2
        max          = 3
      }
      workload_nodes = {
        machine_type = "g2a.8d"
        min          = 2
        max          = 12
      }
      storage_class      = "premium-perf2-stackit"
      fast_storage_class = "premium-perf6-stackit"
      ingress_replicas   = 2
      gdcn_size          = "prod-small"
      pulsar_size        = "prod-small"
      observability_size = "prod-small"
    }
    prod-large = {
      postgresflex = {
        # Largest memory-optimized shape; the memory-optimized line is 2.16,
        # 4.32 then 16.128, so there is nothing between this and prod-small.
        flavor_id      = "16.128-replica"
        storage_class  = "premium-perf6-stackit"
        storage_size   = 128
        retention_days = 90
      }
      system_nodes = {
        machine_type = "g2a.4d"
        min          = 3
        max          = 4
      }
      workload_nodes = {
        machine_type = "g2a.16d"
        min          = 3
        max          = 20
      }
      storage_class      = "premium-perf2-stackit"
      fast_storage_class = "premium-perf6-stackit"
      ingress_replicas   = 3
      gdcn_size          = "prod-large"
      pulsar_size        = "prod-large"
      observability_size = "prod-large"
    }
  }

  profile = local.size_profiles[var.size_profile]

  # Resolved values: profile default unless the matching var.* is set.
  postgresflex_flavor_id     = coalesce(var.postgresflex_flavor_id, local.profile.postgresflex.flavor_id)
  postgresflex_storage_class = coalesce(var.postgresflex_storage_class, local.profile.postgresflex.storage_class)
  # Disk size is not user-configurable; PostgreSQL Flex grows it in place.
  postgresflex_storage_size          = local.profile.postgresflex.storage_size
  postgresflex_backup_retention_days = coalesce(var.postgresflex_backup_retention_days, local.profile.postgresflex.retention_days)
  ske_system_machine_type            = coalesce(var.ske_system_machine_type, local.profile.system_nodes.machine_type)
  ske_system_min_nodes               = coalesce(var.ske_system_min_nodes, local.profile.system_nodes.min)
  ske_system_max_nodes               = local.profile.system_nodes.max
  ske_workload_machine_type          = coalesce(var.ske_workload_machine_type, local.profile.workload_nodes.machine_type)
  ske_workload_min_nodes             = coalesce(var.ske_workload_min_nodes, local.profile.workload_nodes.min)
  ske_workload_max_nodes             = coalesce(var.ske_workload_max_nodes, local.profile.workload_nodes.max)
  # SKE ships these classes; Terraform only references them by name. The fast
  # class backs GoodData.CN's etcd PVC, whose fsync latency Quiver blocks on.
  storage_class      = coalesce(var.stackit_storage_class, local.profile.storage_class)
  fast_storage_class = local.profile.fast_storage_class
}
