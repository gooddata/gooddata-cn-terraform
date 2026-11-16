###
# Provision PostgreSQL Flex for GoodData.CN metadata
#
# Sizing resolved in size-profiles.tf. PostgreSQL Flex generates the user's
# password server-side, so there is no random_password.
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

  # Public endpoint limited to the cluster's egress ranges: access_scope = "SNA" is
  # Private Preview and rejected by the API. The provider needs exactly one of acl/network.acl.
  network = {
    access_scope = "PUBLIC"
    acl          = stackit_ske_cluster.main.egress_address_ranges
  }

  lifecycle {
    # An empty ACL would leave the instance unreachable, and the cause would only
    # surface later as connection failures from the chart.
    precondition {
      condition     = length(stackit_ske_cluster.main.egress_address_ranges) > 0
      error_message = "The SKE cluster reported no egress address ranges, so the PostgreSQL ACL would be empty. Re-run the apply once the cluster reports its ranges."
    }
  }
}

# createdb lets the chart bootstrap its databases; the owner can CREATE EXTENSION
# pg_trgm (trusted since PG 13). createrole lets the gen-ai migration create obs_owner.
resource "stackit_postgresflex_user" "gdcn" {
  project_id  = var.stackit_project_id
  instance_id = stackit_postgresflex_instance.main.instance_id
  username    = local.db_username
  roles       = ["login", "createdb", "createrole"]
}
