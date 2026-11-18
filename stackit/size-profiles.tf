###
# STACKIT sizing per size_profile (prod-xl is AWS-only). The matching var.* input
# overrides any managed value.
###

# SKE has no Karpenter, so capacity comes from a min/max node pool that SKE's cluster
# autoscaler scales. machine_type is the main sizing lever and user-overridable.

# Machine types: g = 1:4 vCPU:RAM, "2a" = AMD gen2, "d" = no overcommit; list with
# `stackit ske options --machine-types`. PG Flex flavors are fixed, so shapes only approximate Azure's.
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
        # The system pool max must be >= the number of availability zones.
        max = 3
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
  # Raised to the zone count: Gardener rejects a pool whose max is below it.
  ske_system_max_nodes      = max(local.profile.system_nodes.max, length(var.stackit_availability_zones))
  ske_workload_machine_type = coalesce(var.ske_workload_machine_type, local.profile.workload_nodes.machine_type)
  ske_workload_min_nodes    = coalesce(var.ske_workload_min_nodes, local.profile.workload_nodes.min)
  ske_workload_max_nodes    = coalesce(var.ske_workload_max_nodes, local.profile.workload_nodes.max)
  # SKE ships these classes; Terraform only references them by name. The fast
  # class backs GoodData.CN's etcd PVC, whose fsync latency Quiver blocks on.
  storage_class      = coalesce(var.stackit_storage_class, local.profile.storage_class)
  fast_storage_class = local.profile.fast_storage_class
}
