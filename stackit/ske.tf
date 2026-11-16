###
# Provision SKE cluster
#
# Sizing resolved in size-profiles.tf. No Karpenter: the autoscaling workload pool scales
# min..max; the system pool stays small, for cluster-critical pods only.
###

locals {
  ske_pool_common = {
    # Spread across all configured zones so a zone loss can't take out every
    # pod in a pool. max_surge must be at least the zone count when set.
    availability_zones = var.stackit_availability_zones
    max_surge          = length(var.stackit_availability_zones)
    volume_size        = 100
    volume_type        = "storage_premium_perf1"
  }
}

resource "stackit_ske_cluster" "main" {
  project_id             = var.stackit_project_id
  name                   = var.deployment_name
  kubernetes_version_min = var.ske_version

  # Append-only: the provider matches node pools by list index when producing a
  # plan, while the API matches by name. Reordering shows a misleading diff.
  node_pools = [
    merge(local.ske_pool_common, {
      name                    = "system"
      machine_type            = local.ske_system_machine_type
      minimum                 = local.ske_system_min_nodes
      maximum                 = local.ske_system_max_nodes
      allow_system_components = true
      # Reserve the pool for system/critical pods so workloads can't starve
      # CoreDNS or metrics-server. Gardener's system components tolerate this.
      taints = [
        {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NoSchedule"
        },
      ]
    }),
    merge(local.ske_pool_common, {
      name                    = "workload"
      machine_type            = local.ske_workload_machine_type
      minimum                 = local.ske_workload_min_nodes
      maximum                 = local.ske_workload_max_nodes
      allow_system_components = false
    }),
  ]

  lifecycle {
    precondition {
      condition     = local.ske_system_min_nodes <= local.ske_system_max_nodes
      error_message = "ske_system_min_nodes (${local.ske_system_min_nodes}) must not exceed the system pool maximum (${local.ske_system_max_nodes})."
    }
    precondition {
      condition     = local.ske_workload_min_nodes <= local.ske_workload_max_nodes
      error_message = "ske_workload_min_nodes (${local.ske_workload_min_nodes}) must not exceed ske_workload_max_nodes (${local.ske_workload_max_nodes})."
    }
    precondition {
      condition     = local.ske_workload_max_nodes >= length(var.stackit_availability_zones)
      error_message = "ske_workload_max_nodes (${local.ske_workload_max_nodes}) must be at least the number of availability zones (${length(var.stackit_availability_zones)}), because Gardener rejects a pool whose maximum is below its zone count. Raise ske_workload_max_nodes or use fewer stackit_availability_zones."
    }
  }

  # API server stays public behind the ACL extension: a private control plane (SNA) is Private
  # Preview, needs a VPN/bastion, and cannot be combined with the ACL extension.
  network = {
    id = stackit_network.main.network_id
    control_plane = {
      access_scope = "PUBLIC"
    }
  }

  extensions = {
    acl = {
      enabled       = true
      allowed_cidrs = var.ske_api_server_authorized_ip_ranges
    }
  }
}

# Short-lived admin kubeconfig for the kubernetes/helm/kubectl providers; refresh
# regenerates it before expiry so plans keep working.
resource "stackit_ske_kubeconfig" "main" {
  project_id   = var.stackit_project_id
  cluster_name = stackit_ske_cluster.main.name

  refresh        = true
  expiration     = 86400
  refresh_before = 3600
}

output "ske_cluster_name" {
  description = "Name of the SKE cluster"
  value       = stackit_ske_cluster.main.name
}

output "ske_egress_address_ranges" {
  description = "Source ranges for traffic leaving the cluster. Use these to allow-list the cluster on external services."
  value       = stackit_ske_cluster.main.egress_address_ranges
}
