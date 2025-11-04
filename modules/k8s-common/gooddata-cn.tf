###
# Deploy GoodData.CN to Kubernetes
###

locals {
  auth_hostname     = "auth.${var.ingress_ip}.${var.wildcard_dns_provider}"
  gdcn_org_hostname = "org.${var.ingress_ip}.${var.wildcard_dns_provider}"
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
      gdcn_replica_count     = var.gdcn_replica_count
      encryption_secret_name = kubernetes_secret.gdcn_encryption.metadata[0].name
      license_secret_name    = kubernetes_secret.gdcn_license.metadata[0].name
      gdcn_org_hostname      = local.gdcn_org_hostname
      auth_hostname          = local.auth_hostname
      db_hostname            = var.db_hostname
      db_username            = var.db_username
      db_password            = var.db_password
      registry_dockerio      = var.registry_dockerio
      registry_quayio        = var.registry_quayio
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

output "auth_hostname" {
  description = "The hostname for GoodData.CN internal authentication (Dex) ingress"
  value       = local.auth_hostname
}

output "gdcn_org_hostname" {
  description = "The hostname for GoodData.CN organization ingress"
  value       = local.gdcn_org_hostname
}
