###
# Cluster network
#
# Only needed for private networking. A routed network in a project that belongs
# to a STACKIT Network Area is reachable from the area, which is what lets the
# control plane and PostgreSQL Flex drop their public endpoints. Attaching the
# project to an area is organization-scoped and happens outside this repo. With
# stackit_private_networking = false, SKE manages its own networking and nothing
# here is created.
#
# There is no NAT gateway to provision: SKE handles node egress itself and
# reports the resulting source ranges as egress_address_ranges, which is what the
# PostgreSQL ACL consumes (see postgresql.tf).
###

resource "stackit_network" "main" {
  count = var.stackit_private_networking ? 1 : 0

  project_id = var.stackit_project_id
  name       = "${var.deployment_name}-network"

  # Prefix is carved out of the network area's ranges. /22 leaves ~1000 node
  # addresses, well above the workload pool ceiling in any size profile.
  ipv4_prefix_length = 22

  # Routed networks are reachable from other networks in the area, which is what
  # makes the SNA control-plane and database endpoints usable.
  routed = true

  labels = local.common_labels
}

locals {
  ske_network_id = var.stackit_private_networking ? stackit_network.main[0].network_id : null
}
