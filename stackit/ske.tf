###
# Provision SKE cluster
#
# Sizing resolved in size-profiles.tf. SKE has no Karpenter provider, so workload
# capacity comes from the autoscaling workload pool below: SKE runs a cluster
# autoscaler on every cluster and scales each pool between its minimum and
# maximum. The system pool stays small and is reserved for cluster-critical pods.
###

resource "stackit_ske_cluster" "main" {
  project_id             = var.stackit_project_id
  name                   = var.deployment_name
  kubernetes_version_min = var.ske_version

  # Append-only: the provider matches node pools by list index when producing a
  # plan, while the API matches by name. Reordering shows a misleading diff.
  node_pools = [
    {
      name         = "system"
      machine_type = local.ske_system_machine_type
      minimum      = local.ske_system_min_nodes
      maximum      = local.ske_system_max_nodes
      # Spread across all configured zones so a zone loss can't take out every
      # system pod. max_surge must be at least the zone count when set.
      availability_zones      = var.stackit_availability_zones
      max_surge               = length(var.stackit_availability_zones)
      volume_size             = 100
      volume_type             = "storage_premium_perf1"
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
    },
    {
      name                    = "workload"
      machine_type            = local.ske_workload_machine_type
      minimum                 = local.ske_workload_min_nodes
      maximum                 = local.ske_workload_max_nodes
      availability_zones      = var.stackit_availability_zones
      max_surge               = length(var.stackit_availability_zones)
      volume_size             = 100
      volume_type             = "storage_premium_perf1"
      allow_system_components = false
    },
  ]

  # Nodes sit in the Network Area network, but the API server stays public behind
  # the ACL extension below. A private control plane (access_scope = "SNA") is a
  # STACKIT Private Preview feature, needs a VPN or bastion to run Terraform, and
  # cannot be combined with the ACL extension.
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

# Short-lived admin kubeconfig for the kubernetes/helm/kubectl providers.
# refresh regenerates it in place before expiry so plans keep working across
# days without re-running anything by hand.
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
