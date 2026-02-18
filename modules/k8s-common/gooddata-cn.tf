###
# Deploy GoodData.CN to Kubernetes
###

locals {
  auth_hostname = trimspace(var.auth_hostname)
  org_ids       = distinct(compact([for org in var.gdcn_orgs : trimspace(org.id)]))
  org_domains   = distinct(compact([for org in var.gdcn_orgs : trimspace(org.hostname)]))
  ingress_annotation_defaults = local.use_ingress_nginx ? merge(
    {
      "nginx.ingress.kubernetes.io/proxy-body-size" = "200m"
    },
    local.use_cert_manager ? {
      "cert-manager.io/cluster-issuer" = local.cert_manager_cluster_issuer_name
    } : {}
  ) : {}
  dex_annotation_defaults = local.use_ingress_nginx ? (
    local.use_cert_manager ? {
      "cert-manager.io/cluster-issuer" = local.cert_manager_cluster_issuer_name
    } : {}
  ) : {}
  ingress_annotations     = merge(local.ingress_annotation_defaults, var.ingress_annotations_override)
  dex_ingress_annotations = merge(local.dex_annotation_defaults, var.dex_ingress_annotations_override)
  dex_tls_enabled         = local.use_cert_manager
}

resource "kubectl_manifest" "peerauth_gdcn_strict" {
  count = local.use_istio_gateway ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1beta1"
    kind       = "PeerAuthentication"
    metadata   = { name = "default", namespace = var.gdcn_namespace }
    spec       = { mtls = { mode = "STRICT" } }
  })

  depends_on = [
    kubernetes_namespace_v1.gdcn,
    helm_release.istiod,
  ]
}

resource "kubernetes_namespace_v1" "gdcn" {
  metadata {
    name = var.gdcn_namespace
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

      # Create a unique temp path and clean it up on exit
      tmpfile="$(mktemp)"
      rm -f "$tmpfile"
      trap 'rm -f "$tmpfile"' EXIT

      # Generate the keyset into that file (tinkey requires --out path must not exist)
      tinkey create-keyset --key-template AES256_GCM --out "$tmpfile" >/dev/null 2>&1

      # Read it, base64-encode, and emit as JSON
      key_json="$(cat "$tmpfile")"

      printf '{"keyset_b64":"%s"}' "$(printf '%s' "$key_json" | base64 | tr -d '\n')"
    EOT
  ]
}

resource "kubernetes_secret_v1" "gdcn_encryption" {
  metadata {
    name      = "gdcn-encryption"
    namespace = kubernetes_namespace_v1.gdcn.metadata[0].name
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

  depends_on = [
    kubernetes_namespace_v1.gdcn,
  ]
}

# Create license secret
resource "kubernetes_secret_v1" "gdcn_license" {
  metadata {
    name      = "gdcn-license"
    namespace = kubernetes_namespace_v1.gdcn.metadata[0].name
  }

  data = {
    license = var.gdcn_license_key
  }

  depends_on = [
    kubernetes_namespace_v1.gdcn,
  ]
}

# Install GoodData.CN
resource "helm_release" "gooddata_cn" {
  name       = "gooddata-cn"
  repository = "https://charts.gooddata.com/"
  chart      = "gooddata-cn"
  version    = var.helm_gdcn_version
  namespace  = kubernetes_namespace_v1.gdcn.metadata[0].name

  values = compact([
    templatefile("${path.module}/templates/gdcn-base.yaml.tftpl", {
      encryption_secret_name  = kubernetes_secret_v1.gdcn_encryption.metadata[0].name
      license_secret_name     = kubernetes_secret_v1.gdcn_license.metadata[0].name
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
    var.cloud == "local" ? templatefile("${path.module}/templates/gdcn-local.yaml.tftpl", {
      s3_endpoint_override    = var.local_s3_endpoint_override
      s3_region               = var.local_s3_region
      s3_access_key           = var.local_s3_access_key
      s3_secret_key           = var.local_s3_secret_key
      s3_exports_bucket       = var.local_s3_exports_bucket
      s3_datasource_fs_bucket = var.local_s3_datasource_fs_bucket
      s3_quiver_cache_bucket  = var.local_s3_quiver_cache_bucket
    }) : null,
    templatefile("${path.module}/templates/gdcn-size-${var.size_profile}.yaml.tftpl", {})
  ])

  # Wait until all resources are ready before Terraform continues
  wait          = true
  wait_for_jobs = true
  timeout       = 1800

  depends_on = [
    kubernetes_namespace_v1.gdcn,
    helm_release.pulsar,
    helm_release.ingress_nginx,
    kubectl_manifest.letsencrypt_cluster_issuer,
    kubectl_manifest.selfsigned_cluster_issuer,
    helm_release.istio_ingress_gateway,
    kubectl_manifest.istio_public_gateway,
  ]
}

resource "kubectl_manifest" "export_builder_localhost_forwarder" {
  count = var.cloud == "local" && local.use_ingress_nginx ? 1 : 0

  server_side_apply = true
  force_conflicts   = true

  yaml_body = <<-YAML
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: gooddata-cn-export-builder
      namespace: ${kubernetes_namespace_v1.gdcn.metadata[0].name}
    spec:
      template:
        spec:
          containers:
            - name: localhost-forwarder
              image: ${var.registry_dockerio}/alpine/socat:1.8.0.3
              imagePullPolicy: IfNotPresent
              command:
                - /bin/sh
                - -ec
                - |
                  socat TCP4-LISTEN:443,bind=127.0.0.1,reuseaddr,fork TCP4:ingress-nginx-controller.ingress-nginx.svc.cluster.local:443 &
                  socat TCP6-LISTEN:443,bind=[::1],reuseaddr,fork TCP4:ingress-nginx-controller.ingress-nginx.svc.cluster.local:443 &
                  wait
              securityContext:
                allowPrivilegeEscalation: false
                runAsNonRoot: false
                runAsUser: 0
                capabilities:
                  drop:
                    - ALL
                  add:
                    - NET_BIND_SERVICE
              resources:
                limits:
                  cpu: 50m
                  memory: 64Mi
                requests:
                  cpu: 10m
                  memory: 32Mi
  YAML

  depends_on = [
    helm_release.gooddata_cn,
  ]
}

output "auth_hostname" {
  description = "The hostname for GoodData.CN internal authentication (Dex) ingress"
  value       = local.auth_hostname
}

output "ingress_class_name" {
  description = "Ingress class name applied to GoodData.CN ingress resources"
  value       = local.resolved_ingress_class_name
}

output "org_domains" {
  description = "All GoodData.CN organization hostnames derived from gdcn_orgs"
  value       = local.org_domains
}

output "org_ids" {
  description = "List of organization IDs/DNS labels allowed by this deployment"
  value       = local.org_ids
}
