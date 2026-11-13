###
# Cluster network
#
# The SKE nodes and load balancer get private addresses from this routed network,
# which is carved out of the STACKIT Network Area that the project belongs to.
# Attaching the project to an area is organization-scoped and happens outside
# this repo.
#
# There is no NAT gateway to provision: SKE handles node egress itself and
# reports the resulting source ranges as egress_address_ranges, which is what the
# PostgreSQL ACL consumes (see postgresql.tf).
###

resource "stackit_network" "main" {
  project_id = var.stackit_project_id
  name       = "${var.deployment_name}-network"

  # Prefix is carved out of the network area's ranges. /22 leaves ~1000 node
  # addresses, well above the workload pool ceiling in any size profile.
  ipv4_prefix_length = 22

  # Routed networks are reachable from other networks in the area.
  routed = true

  labels = local.common_labels
}
