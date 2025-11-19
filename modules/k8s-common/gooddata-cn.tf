###
# Deploy GoodData.CN to Kubernetes
###

locals {
  use_ingress_nginx    = var.ingress_controller == "ingress-nginx"
  base_domain_input    = trimspace(var.base_domain)
  fallback_auth_domain = var.ingress_ip != "" && var.wildcard_dns_provider != "" ? "auth.${var.ingress_ip}.${var.wildcard_dns_provider}" : ""
  fallback_org_domain  = var.ingress_ip != "" && var.wildcard_dns_provider != "" ? "org.${var.ingress_ip}.${var.wildcard_dns_provider}" : ""
  fallback_base_domain = var.ingress_ip != "" && var.wildcard_dns_provider != "" ? "${var.deployment_name}.${var.ingress_ip}.${var.wildcard_dns_provider}" : ""
  base_domain          = local.base_domain_input != "" ? local.base_domain_input : local.fallback_base_domain
  default_auth_domain  = local.base_domain != "" ? "auth.${local.base_domain}" : local.fallback_auth_domain
  default_org_domain   = local.base_domain != "" ? "org.${local.base_domain}" : local.fallback_org_domain
  auth_domain          = local.default_auth_domain
  org_domain           = local.default_org_domain
  ingress_class_name   = trimspace(var.ingress_class_name_override) != "" ? trimspace(var.ingress_class_name_override) : "nginx"
  ingress_annotation_defaults = local.use_ingress_nginx ? {
    "cert-manager.io/cluster-issuer"              = "letsencrypt"
    "nginx.ingress.kubernetes.io/proxy-body-size" = "200m"
  } : {}
  dex_annotation_defaults = local.use_ingress_nginx ? {
    "cert-manager.io/cluster-issuer" = "letsencrypt"
  } : {}
  ingress_annotations     = merge(local.ingress_annotation_defaults, var.ingress_annotations_override)
  dex_ingress_annotations = merge(local.dex_annotation_defaults, var.dex_ingress_annotations_override)
  dex_tls_enabled         = local.use_ingress_nginx
}

resource "kubernetes_namespace" "gdcn" {
  metadata {
    name = var.gdcn_namespace
  }

  depends_on = [helm_release.cert-manager]
}

# Generate an AES‑256‑GCM keyset with Tinkey and capture it as base64
data "external" "tinkey_keyset" {
  program = [
    "bash",
    "-c",
    <<-EOT
      set -euo pipefail

      # Get a unique **unused** filename
      tmpfile="$(mktemp -u)"

      # Generate the keyset into that file
      tinkey create-keyset --key-template AES256_GCM --out "$tmpfile" >/dev/null 2>&1

      # Read it, base64-encode, and emit as JSON
      key_json="$(cat "$tmpfile")"
      rm -f "$tmpfile"

      printf '{"keyset_b64":"%s"}' "$(printf '%s' "$key_json" | base64 -w0)"
    EOT
  ]
}

resource "kubernetes_secret" "gdcn_encryption" {
  metadata {
    name      = "gdcn-encryption"
    namespace = kubernetes_namespace.gdcn.metadata[0].name
  }

  data = {
    keySet = base64decode(data.external.tinkey_keyset.result.keyset_b64)
  }

  lifecycle {
    # After the first successful apply, never reconcile
    # the `data` field again unless you taint/replace the
    # resource manually.
    ignore_changes = [data]
  }
}

# Create license secret
resource "kubernetes_secret" "gdcn_license" {
  metadata {
    name      = "gdcn-license"
    namespace = kubernetes_namespace.gdcn.metadata[0].name
  }

  data = {
    license = var.gdcn_license_key
  }
}

# Install GoodData.CN
resource "helm_release" "gooddata_cn" {
  name       = "gooddata-cn"
  repository = "https://charts.gooddata.com/"
  chart      = "gooddata-cn"
  version    = var.helm_gdcn_version
  namespace  = kubernetes_namespace.gdcn.metadata[0].name

  values = compact([
    templatefile("${path.module}/templates/gdcn-base.yaml.tftpl", {
      gdcn_replica_count      = var.gdcn_replica_count
      encryption_secret_name  = kubernetes_secret.gdcn_encryption.metadata[0].name
      license_secret_name     = kubernetes_secret.gdcn_license.metadata[0].name
      org_domain              = local.org_domain
      auth_domain             = local.auth_domain
      base_domain             = local.base_domain
      db_hostname             = var.db_hostname
      db_username             = var.db_username
      db_password             = var.db_password
      registry_dockerio       = var.registry_dockerio
      registry_quayio         = var.registry_quayio
      ingress_class_name      = local.ingress_class_name
      ingress_annotations     = local.ingress_annotations
      dex_ingress_annotations = local.dex_ingress_annotations
      dex_tls_enabled         = local.dex_tls_enabled
    }),
    var.use_image_cache ? templatefile("${path.module}/templates/gdcn-image-cache.yaml.tftpl", {
      registry_dockerio = var.registry_dockerio,
      registry_quayio   = var.registry_quayio
    }) : null,
    var.cloud == "azure" ? templatefile("${path.module}/templates/gdcn-azure.yaml.tftpl", {
      gdcn_service_account_name     = var.gdcn_service_account_name
      azure_uami_client_id          = var.azure_uami_client_id
      azure_storage_account_name    = var.azure_storage_account_name
      azure_exports_container       = var.azure_exports_container
      azure_quiver_container        = var.azure_quiver_container
      azure_datasource_fs_container = var.azure_datasource_fs_container
    }) : null,
    var.cloud == "aws" ? templatefile("${path.module}/templates/gdcn-aws.yaml.tftpl", {
      aws_region                 = var.aws_region
      s3_exports_bucket_id       = var.s3_exports_bucket_id
      s3_quiver_cache_bucket_id  = var.s3_quiver_cache_bucket_id
      s3_datasource_fs_bucket_id = var.s3_datasource_fs_bucket_id
      gdcn_service_account_name  = var.gdcn_service_account_name
      gdcn_irsa_role_arn         = var.gdcn_irsa_role_arn
    }) : null,
    templatefile("${path.module}/templates/gdcn-size-tiny.yaml.tftpl", {})
  ])

  # Wait until all resources are ready before Terraform continues
  timeout = 1800

  depends_on = [
    kubernetes_namespace.gdcn,
    helm_release.pulsar
  ]
}

output "base_domain" {
  description = "Base domain used for constructing GoodData hostnames"
  value       = local.base_domain
}

output "auth_domain" {
  description = "The hostname for GoodData.CN internal authentication (Dex) ingress"
  value       = local.auth_domain
}

output "org_domain" {
  description = "The hostname for GoodData.CN organization ingress"
  value       = local.org_domain
}

output "ingress_class_name" {
  description = "Ingress class name applied to GoodData.CN ingress resources"
  value       = local.ingress_class_name
}
