###
# Manage GoodData.CN Organization custom resources (optional)
#
# - If var.gdcn_orgs is empty, Terraform does not create any Organization objects.
# - When created, we generate a per-org admin password and store it in:
#   - Organization.spec.adminUserToken (crypt hash, sha512-crypt)
#   - a Kubernetes Secret (plaintext) so scripts can use it without prompting
#
# Organization TLS (spec.tls):
# - cert-manager -> secretName = `${org.id}-tls` (+ issuer fields)
# - istio        -> this module uses `istio.gateway.existingGateway`, so Organization.spec.tls
#                  is ignored by the chart/controller.
###

locals {
  orgs_trimmed = [
    for org in var.gdcn_orgs : {
      id          = trimspace(org.id)
      name        = trimspace(org.name)
      admin_user  = trimspace(org.admin_user)
      admin_group = trimspace(org.admin_group)
      hostname    = trimspace(org.hostname)
    }
  ]

  managed_orgs_by_id = {
    for org in local.orgs_trimmed : org.id => merge(org, {
      tls = local.use_cert_manager ? {
        tls = {
          secretName = "${org.id}-tls"
          issuerName = local.cert_manager_cluster_issuer_name
          issuerType = "ClusterIssuer"
        }
      } : {}
    }) if org.id != ""
  }
}

resource "random_password" "gdcn_org_admin_password" {
  for_each = local.managed_orgs_by_id

  length  = 24
  special = true

  # Keep this friendly for:
  # - URL/CLI usage
  # - our bootstrap token format: "user:bootstrap:password"
  # (avoid ':' and whitespace)
  override_special = "_%@-"
}

resource "random_password" "gdcn_org_admin_salt" {
  for_each = local.managed_orgs_by_id

  length  = 16
  special = false
}

data "external" "gdcn_org_admin_user_token_hash" {
  for_each = local.managed_orgs_by_id

  program = [
    "bash",
    "-c",
    <<-EOT
      set -euo pipefail

      if ! command -v openssl >/dev/null 2>&1; then
        echo "openssl is required to generate the Organization admin token hash." >&2
        exit 1
      fi

      # external data source passes JSON on stdin, e.g.:
      # {"password":"...","salt":"..."}
      #
      # We avoid jq/python dependencies here. This parser assumes the values do not
      # contain unescaped double-quotes, which is guaranteed by our random_password
      # configuration (no `"` in override_special).
      query="$(cat)"
      pw="$${query#*\"password\":\"}"
      if [[ "$${pw}" == "$${query}" ]]; then
        pw=""
      else
        pw="$${pw%%\"*}"
      fi

      salt="$${query#*\"salt\":\"}"
      if [[ "$${salt}" == "$${query}" ]]; then
        salt=""
      else
        salt="$${salt%%\"*}"
      fi

      if [[ -z "$${pw}" || -z "$${salt}" ]]; then
        echo "failed to parse external query json: $${query}" >&2
        exit 1
      fi

      h="$(openssl passwd -6 -salt "$${salt}" "$${pw}")"
      printf '{"hash":"%s"}\n' "$${h}"
    EOT
  ]

  query = {
    password = random_password.gdcn_org_admin_password[each.key].result
    salt     = random_password.gdcn_org_admin_salt[each.key].result
  }
}

resource "kubernetes_secret_v1" "gdcn_org_admin" {
  for_each = local.managed_orgs_by_id

  metadata {
    name      = "gdcn-org-admin-${each.key}"
    namespace = var.gdcn_namespace
  }

  type = "Opaque"
  data = {
    orgId             = each.key
    hostname          = each.value.hostname
    adminUser         = each.value.admin_user
    adminPassword     = random_password.gdcn_org_admin_password[each.key].result
    bootstrapTokenRaw = "${each.value.admin_user}:bootstrap:${random_password.gdcn_org_admin_password[each.key].result}"
  }

  depends_on = [
    kubernetes_namespace_v1.gdcn,
  ]
}

resource "kubectl_manifest" "gdcn_organization" {
  for_each = local.managed_orgs_by_id

  yaml_body = yamlencode({
    apiVersion = "controllers.gooddata.com/v1"
    kind       = "Organization"
    metadata = {
      name      = "${each.key}-org"
      namespace = var.gdcn_namespace
    }
    spec = merge({
      id             = each.key
      name           = each.value.name
      hostname       = each.value.hostname
      adminGroup     = each.value.admin_group
      adminUser      = each.value.admin_user
      adminUserToken = data.external.gdcn_org_admin_user_token_hash[each.key].result.hash
    }, each.value.tls)
  })

  lifecycle {
    precondition {
      condition     = each.value.name != ""
      error_message = "Organization '${each.key}' is missing required field: name"
    }
    precondition {
      condition     = each.value.admin_user != ""
      error_message = "Organization '${each.key}' is missing required field: admin_user"
    }
    precondition {
      condition     = each.value.admin_group != ""
      error_message = "Organization '${each.key}' is missing required field: admin_group"
    }
    precondition {
      condition     = each.value.hostname != ""
      error_message = "Organization '${each.key}' hostname must be provided in gdcn_orgs."
    }
  }

  depends_on = [
    helm_release.gooddata_cn,
    kubernetes_secret_v1.gdcn_org_admin,
  ]
}

