###
# All Azure sizing per size_profile. Managed infra (PostgreSQL, AKS system
# nodes, Karpenter/NAP vCPU bounds, ingress replicas) is defined inline;
# GoodData.CN, Pulsar and observability sizing is referenced by name. prod-xl
# is AWS-only. Managed values are overridable by the matching var.* input where
# one exists; PostgreSQL storage size and tier are profile-fixed (see below).
###

locals {
  size_profiles = {
    dev = {
      postgresql = {
        sku_name     = "B_Standard_B2s"
        storage_mb   = 32768
        storage_tier = null
      }
      postgres = {
        work_mem_mb             = 8
        maintenance_work_mem_mb = 128
      }
      system_node_vm_size = "Standard_D4as_v6"
      aks_node_counts = {
        min = 1
      }
      node_cpu_limit     = 48
      node_cpu_max       = 8
      storage_class      = "managed-csi"
      ingress_replicas   = 1
      gdcn_size          = "dev"
      pulsar_size        = "dev"
      observability_size = "dev"
    }
    prod-small = {
      postgresql = {
        sku_name = "GP_Standard_D4ds_v5"
        # 128 GB is the smallest step at or above 100 GB; autogrow (postgresql.tf)
        # grows it. P20 pins ~2300 IOPS, which untiered storage needs 512 GB for.
        storage_mb   = 131072
        storage_tier = "P20"
      }
      postgres = {
        work_mem_mb             = 16
        maintenance_work_mem_mb = 256
      }
      system_node_vm_size = "Standard_D4as_v6"
      aks_node_counts = {
        min = 2
      }
      node_cpu_limit     = 96
      node_cpu_max       = 8
      storage_class      = "premium-ssd-v2"
      ingress_replicas   = 2
      gdcn_size          = "prod-small"
      pulsar_size        = "prod-small"
      observability_size = "prod-small"
    }
    prod-large = {
      postgresql = {
        sku_name     = "MO_Standard_E8ds_v5"
        storage_mb   = 524288
        storage_tier = "P20"
      }
      postgres = {
        work_mem_mb             = 32
        maintenance_work_mem_mb = 512
      }
      system_node_vm_size = "Standard_D4as_v6"
      aks_node_counts = {
        min = 3
      }
      node_cpu_limit     = 320
      node_cpu_max       = 16
      storage_class      = "premium-ssd-v2"
      ingress_replicas   = 3
      gdcn_size          = "prod-large"
      pulsar_size        = "prod-large"
      observability_size = "prod-large"
    }
  }

  profile = local.size_profiles[var.size_profile]

  # Resolved values: profile default unless the matching var.* is set.
  postgresql_sku_name = coalesce(var.postgresql_sku_name, local.profile.postgresql.sku_name)
  # Disk size and its performance tier; not user-configurable, since Azure
  # rejects a tier below the one its size implies. dev leaves the tier null so
  # Azure derives it; prod pins P20 to get IOPS without a bigger disk.
  postgresql_storage_mb   = coalesce(var.postgresql_storage_mb, local.profile.postgresql.storage_mb)
  postgresql_storage_tier = local.profile.postgresql.storage_tier
  # Prod keeps 14 days of point-in-time recovery, dev the 7-day minimum.
  postgresql_is_prod               = startswith(var.size_profile, "prod")
  postgresql_backup_retention_days = coalesce(var.postgresql_backup_retention_days, local.postgresql_is_prod ? 14 : 7)
  aks_min_nodes                    = coalesce(var.aks_min_nodes, local.profile.aks_node_counts.min)
  # VM size of the system pool; not user-configurable. Karpenter sizes the
  # workload nodes, using the vCPU bounds below.
  system_node_vm_size = local.profile.system_node_vm_size
  # Ceiling on total workload vCPUs Karpenter may run (NodePool spec.limits.cpu).
  aks_node_cpu_limit = coalesce(var.aks_node_cpu_limit, local.profile.node_cpu_limit)
  # Largest workload node Karpenter may pick, in vCPUs (NodePool sku-cpu Lt).
  # The Das series it selects from has no member below 2 vCPU, so no floor is set.
  aks_node_cpu_max = coalesce(var.aks_node_cpu_max, local.profile.node_cpu_max)
  # StorageClass for GoodData.CN chart PVCs: managed-csi on dev,
  # premium-ssd-v2 on prod.
  storage_class = coalesce(var.azure_storage_class, local.profile.storage_class)
}
