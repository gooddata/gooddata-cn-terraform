###
# DNS automation via the SKE DNS extension
#
# When dns_provider = "stackit-dns", Terraform creates a STACKIT DNS zone and
# enables SKE's DNS extension (see ske.tf), which runs a managed externalDNS in
# the cluster and maintains records for each GoodData hostname. There is no
# self-hosted external-dns release, service account or credential to deploy.
###

locals {
  external_dns_enabled   = var.dns_provider == "stackit-dns"
  external_dns_zone_name = local.external_dns_enabled ? trimspace(var.stackit_dns_zone_name) : ""

  # All hostnames Terraform expects to surface via DNS.
  external_dns_managed_hosts = local.external_dns_enabled ? distinct(compact(concat(
    [trimspace(var.auth_hostname)],
    [for org in var.gdcn_orgs : trimspace(org.hostname)],
    var.enable_observability ? [trimspace(var.observability_hostname)] : []
  ))) : []
}

# A hostname outside the zone silently never gets a record, and cert-manager then
# backs off for up to 32h after the failed ACME challenge. Fail the plan instead.
resource "terraform_data" "validate_stackit_dns_hostnames" {
  count = local.external_dns_enabled ? 1 : 0

  input = local.external_dns_zone_name

  lifecycle {
    precondition {
      condition = alltrue([
        for host in local.external_dns_managed_hosts :
        host == local.external_dns_zone_name || endswith(host, ".${local.external_dns_zone_name}")
      ])
      error_message = "Every GoodData hostname must sit inside stackit_dns_zone_name when dns_provider = \"stackit-dns\"."
    }
  }
}

resource "stackit_dns_zone" "main" {
  count = local.external_dns_enabled ? 1 : 0

  project_id = var.stackit_project_id
  name       = var.deployment_name
  dns_name   = local.external_dns_zone_name

  contact_email = var.letsencrypt_email

  depends_on = [terraform_data.validate_stackit_dns_hostnames]
}

output "stackit_dns_primary_name_server" {
  description = "Primary name server for the STACKIT DNS zone (when dns_provider = \"stackit-dns\"). Delegate the zone at your registrar; the full name server set is listed for the zone in the STACKIT Portal."
  value       = local.external_dns_enabled ? stackit_dns_zone.main[0].primary_name_server : ""
}
