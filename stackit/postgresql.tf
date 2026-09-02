###
# Provision PostgreSQL Flex for GoodData.CN metadata
#
# Sizing resolved in size-profiles.tf. Unlike the other clouds there is no
# random_password here: PostgreSQL Flex generates the user's password server-side
# and the provider exposes it as a read-only attribute.
###

locals {
  db_username = "gooddata"
  db_password = stackit_postgresflex_user.gdcn.password
  db_hostname = stackit_postgresflex_instance.main.connection_info.write.host
}

resource "stackit_postgresflex_instance" "main" {
  project_id = var.stackit_project_id
  name       = "${var.deployment_name}-postgresql"
  version    = "16"

  flavor_id = local.postgresflex_flavor_id
  storage = {
    class = local.postgresflex_storage_class
    size  = local.postgresflex_storage_size
  }

  backup_schedule = "0 2 * * *"
  retention_days  = local.postgresflex_backup_retention_days

  # SNA keeps the instance off the public internet; the public fallback is
  # reachable only from the cluster. Either way an ACL is mandatory: the provider
  # requires exactly one of acl or network.acl, so leaving it null is rejected.
  # Egress ranges are the real source of database traffic in both access scopes,
  # and the network prefix is added under SNA so in-network clients still reach it.
  network = {
    access_scope = var.stackit_private_networking ? "SNA" : "PUBLIC"
    acl = distinct(concat(
      stackit_ske_cluster.main.egress_address_ranges,
      var.stackit_private_networking ? stackit_network.main[0].ipv4_prefixes : [],
    ))
  }

  lifecycle {
    # An empty ACL would leave the instance unreachable, and the cause would only
    # surface later as connection failures from the chart.
    precondition {
      condition     = length(stackit_ske_cluster.main.egress_address_ranges) > 0
      error_message = "The SKE cluster reported no egress address ranges, so the PostgreSQL ACL would be empty. Set postgresflex ACLs manually or re-run once the cluster reports its ranges."
    }
  }
}

# createdb lets the GoodData.CN chart bootstrap its own metadata databases, the
# same way the admin login does on the other clouds. The user owns every database
# it creates, which is enough to CREATE EXTENSION pg_trgm — trusted since
# PostgreSQL 13 — so no server-parameter allow-listing is needed here.
resource "stackit_postgresflex_user" "gdcn" {
  project_id  = var.stackit_project_id
  instance_id = stackit_postgresflex_instance.main.instance_id
  username    = local.db_username
  roles       = ["login", "createdb"]
}
