###
# Deploy GoodData.CN to Kubernetes
###

locals {
  auth_hostname = trimspace(var.auth_hostname)
  org_ids       = distinct(compact([for org in var.gdcn_orgs : trimspace(org.id)]))
  org_domains   = distinct(compact([for org in var.gdcn_orgs : trimspace(org.hostname)]))
  ingress_annotation_defaults = local.use_ingress_nginx ? {
    "cert-manager.io/cluster-issuer"              = "letsencrypt"
    "nginx.ingress.kubernetes.io/proxy-body-size" = "200m"
  } : {}
  dex_annotation_defaults = local.use_ingress_nginx ? {
    "cert-manager.io/cluster-issuer" = "letsencrypt"
  } : {}
  ingress_annotations     = merge(local.ingress_annotation_defaults, var.ingress_annotations_override)
  dex_ingress_annotations = merge(local.dex_annotation_defaults, var.dex_ingress_annotations_override)
  dex_tls_enabled         = local.use_cert_manager
}

resource "kubernetes_namespace" "gdcn" {
  metadata {
    name = local.gdcn_namespace
    labels = local.use_istio_gateway ? {
      "istio-injection" = "enabled"
    } : null
  }
}

# Generate an AES‑256‑GCM keyset with Tinkey and capture it as base64
data "external" "tinkey_keyset" {
  program = [
    "bash",
    "-c",
    <<-EOT
      set -euo pipefail

      # Get a unique temp file path and clean it up on exit
      tmpfile="$(mktemp -u)"
      trap 'rm -f "$tmpfile"' EXIT

      # Generate the keyset into that file
      tinkey create-keyset --key-template AES256_GCM --out "$tmpfile" >/dev/null 2>&1

      # Read it, base64-encode, and emit as JSON
      key_json="$(cat "$tmpfile")"

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
      encryption_secret_name  = kubernetes_secret.gdcn_encryption.metadata[0].name
      license_secret_name     = kubernetes_secret.gdcn_license.metadata[0].name
      org_domains             = local.org_domains
      auth_hostname           = local.auth_hostname
      db_hostname             = var.db_hostname
      db_username             = var.db_username
      db_password             = var.db_password
      registry_dockerio       = var.registry_dockerio
      registry_quayio         = var.registry_quayio
      ingress_class_name      = local.resolved_ingress_class_name
      ingress_annotations     = local.ingress_annotations
      dex_ingress_annotations = local.dex_ingress_annotations
      dex_tls_enabled         = local.dex_tls_enabled
      dex_tls_secret_name     = "gooddata-cn-auth-tls"
    }),
    local.use_istio_gateway ? templatefile("${path.module}/templates/gdcn-istio.yaml.tftpl", {
      existing_gateway = "istio-ingress/${local.istio_public_gateway_name}"
    }) : null,
    var.enable_ai_features ? templatefile("${path.module}/templates/gdcn-ai-features.yaml.tftpl", {}) : null,
    var.enable_image_cache ? templatefile("${path.module}/templates/gdcn-image-cache.yaml.tftpl", {
      registry_dockerio = var.registry_dockerio,
      registry_quayio   = var.registry_quayio
    }) : null,
    var.cloud == "azure" ? templatefile("${path.module}/templates/gdcn-azure.yaml.tftpl", {
      gdcn_service_account_name     = local.gdcn_service_account_name
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
      gdcn_service_account_name  = local.gdcn_service_account_name
      gdcn_irsa_role_arn         = var.gdcn_irsa_role_arn
    }) : null,
    templatefile("${path.module}/templates/gdcn-size-${var.size_profile}.yaml.tftpl", {})
  ])

  # Wait until all resources are ready before Terraform continues
  wait          = true
  wait_for_jobs = true
  timeout       = 1800

  depends_on = [
    kubernetes_namespace.gdcn,
    helm_release.pulsar,
    kubectl_manifest.letsencrypt_cluster_issuer,
    helm_release.istio_ingress_gateway,
    kubectl_manifest.istio_public_gateway,
  ]
}

output "auth_hostname" {
  description = "The hostname for GoodData.CN internal authentication (Dex) ingress"
  value       = local.auth_hostname
}

output "org_domains" {
  description = "All GoodData.CN organization hostnames derived from gdcn_orgs"
  value       = local.org_domains
}

output "org_ids" {
  description = "List of organization IDs/DNS labels allowed by this deployment"
  value       = local.org_ids
}

output "ingress_class_name" {
  description = "Ingress class name applied to GoodData.CN ingress resources"
  value       = local.resolved_ingress_class_name
}
