###
# Cluster network
#
# Routed network from the project's Network Area (attached outside this repo).
# No NAT gateway: SKE reports egress_address_ranges, which the PostgreSQL ACL uses.
###

resource "stackit_network" "main" {
  project_id = var.stackit_project_id
  name       = "${var.deployment_name}-network"

  # /22 leaves ~1000 node addresses, above the pool ceiling of any size profile.
  ipv4_prefix_length = 22

  # Routed networks are reachable from other networks in the area.
  routed = true

  labels = local.common_labels
}
