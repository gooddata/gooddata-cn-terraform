###
# GoodData.CN Organizations
###

# Default organization
resource "kubernetes_manifest" "default_organization" {
  count = var.create_default_organization ? 1 : 0

  manifest = {
    apiVersion = "controllers.gooddata.com/v1"
    kind       = "Organization"
    metadata = {
      name      = var.default_org_name
      namespace = kubernetes_namespace.gdcn.metadata[0].name
    }
    spec = {
      id         = var.default_org_id
      name       = var.default_org_display_name
      hostname   = local.gdcn_org_hostname
      adminGroup = "adminGroup"
      adminUser  = "admin-${var.default_org_id}"
    }
  }

  depends_on = [
    helm_release.gooddata_cn,
    kubernetes_namespace.gdcn
  ]
}

output "default_organization_id" {
  description = "The ID of the default organization (if created)"
  value       = var.create_default_organization ? var.default_org_id : null
}

output "default_organization_hostname" {
  description = "The hostname of the default organization (if created)"
  value       = var.create_default_organization ? local.gdcn_org_hostname : null
}
