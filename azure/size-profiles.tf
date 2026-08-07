###
# Single source of truth for Azure sizing per size_profile: managed infra
# (PostgreSQL, AKS nodes, Karpenter/NAP node CPU ceiling, ingress replicas) inline, plus
# workload (GoodData.CN/Pulsar/observability) sizing referenced by name. prod-xl
# is not valid on Azure. Override any managed value via the matching var.* input.
###

locals {
  size_profiles = {
    dev = {
      postgresql = {
        sku_name   = "B_Standard_B2s"
        storage_mb = 32768
      }
      postgres = {
        work_mem_mb             = 8
        maintenance_work_mem_mb = 128
      }
      system_node_vm_size = "Standard_D4as_v6"
      aks_node_counts = {
        min = 1
      }
      node_cpu_limit     = 24
      node_cpu_max       = 4
      storage_class      = "managed-csi"
      ingress_replicas   = 1
      gdcn_size          = "dev"
      pulsar_size        = "dev"
      observability_size = "dev"
    }
    prod-small = {
      postgresql = {
        sku_name   = "GP_Standard_D4ds_v5"
        storage_mb = 131072
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
        sku_name = "MO_Standard_E8ds_v5"
        # 512 GB for IOPS headroom under load (v1 storage IOPS scale with size:
        # ~2300 @ 512 GB vs ~500 @ 128 GB). Overridable via var.postgresql_storage_mb.
        storage_mb = 524288
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

  # Resolved managed values (profile default, overridable via var.*).
  postgresql_sku_name = coalesce(var.postgresql_sku_name, local.profile.postgresql.sku_name)
  # Prod keeps 14 days of point-in-time recovery, dev the 7-day minimum.
  postgresql_is_prod               = startswith(var.size_profile, "prod")
  postgresql_backup_retention_days = coalesce(var.postgresql_backup_retention_days, local.postgresql_is_prod ? 14 : 7)
  postgresql_storage_mb            = coalesce(var.postgresql_storage_mb, local.profile.postgresql.storage_mb)
  aks_min_nodes                    = coalesce(var.aks_min_nodes, local.profile.aks_node_counts.min)
  # System pool VM size (not user-configurable). Workload nodes are sized by
  # Karpenter (sku-family + CPU bounds below).
  system_node_vm_size = local.profile.system_node_vm_size
  # Total workload vCPU ceiling (NodePool spec.limits.cpu).
  aks_node_cpu_limit = coalesce(var.aks_node_cpu_limit, local.profile.node_cpu_limit)
  # Per-node vCPU cap for workload nodes (NodePool sku-cpu Lt) within the D family.
  aks_node_cpu_max = coalesce(var.aks_node_cpu_max, local.profile.node_cpu_max)
  # StorageClass for GoodData.CN chart PVCs (standard for dev, premium for prod).
  # Overridable via var.azure_storage_class.
  storage_class = coalesce(var.azure_storage_class, local.profile.storage_class)
}
