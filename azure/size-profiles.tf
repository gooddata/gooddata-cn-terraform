###
# Single source of truth for Azure sizing per size_profile: managed infra
# (PostgreSQL, AKS nodes, autoscaler bounds, ingress replicas) inline, plus
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
      aks_node_vm_sizes = ["Standard_D4as_v6", "Standard_D2as_v6"]
      aks_node_counts = {
        min = 1
        max = 6
      }
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
      aks_node_vm_sizes = ["Standard_D4as_v6", "Standard_D2as_v6", "Standard_D8as_v6"]
      aks_node_counts = {
        min = 2
        max = 12
      }
      ingress_replicas   = 2
      gdcn_size          = "prod-small"
      pulsar_size        = "prod-small"
      observability_size = "prod-small"
    }
    prod-large = {
      postgresql = {
        sku_name   = "MO_Standard_E4ds_v5"
        storage_mb = 131072
      }
      postgres = {
        work_mem_mb             = 32
        maintenance_work_mem_mb = 512
      }
      aks_node_vm_sizes = ["Standard_D4as_v6", "Standard_D2as_v6", "Standard_D8as_v6", "Standard_D16as_v6"]
      aks_node_counts = {
        min = 3
        max = 20
      }
      ingress_replicas   = 3
      gdcn_size          = "prod-large"
      pulsar_size        = "prod-large"
      observability_size = "prod-large"
    }
  }

  profile = local.size_profiles[var.size_profile]

  # Resolved managed values (profile default, overridable via var.*).
  postgresql_sku_name   = coalesce(var.postgresql_sku_name, local.profile.postgresql.sku_name)
  postgresql_storage_mb = coalesce(var.postgresql_storage_mb, local.profile.postgresql.storage_mb)
  aks_node_vm_sizes     = coalesce(var.aks_node_vm_sizes, local.profile.aks_node_vm_sizes)
  aks_min_nodes         = coalesce(var.aks_min_nodes, local.profile.aks_node_counts.min)
  aks_max_nodes         = coalesce(var.aks_max_nodes, local.profile.aks_node_counts.max)
}
