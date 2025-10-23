###
# Deploy GoodData.CN to Kubernetes
###

locals {
  auth_hostname     = "auth.${var.ingress_ip}.${var.wildcard_dns_provider}"
  gdcn_org_hostname = "org.${var.ingress_ip}.${var.wildcard_dns_provider}"
}

resource "kubernetes_namespace" "gdcn" {
  metadata {
    name = "gooddata-cn"
  }
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

# Azure Storage credentials for quiver S3 durable storage
resource "kubernetes_secret" "gdcn_azure_storage" {
  # Count removed: Azure storage is always present in this deployment
  # The conditional was causing "count depends on resource attributes" error
  
  metadata {
    name      = "gooddata-cn-secrets"
    namespace = kubernetes_namespace.gdcn.metadata[0].name
    
    # Add Helm ownership labels/annotations to prevent conflicts
    labels = {
      "app.kubernetes.io/managed-by" = "Helm"
    }
    
    annotations = {
      "meta.helm.sh/release-name"      = "gooddata-cn"
      "meta.helm.sh/release-namespace" = "gooddata-cn"
    }
  }

  data = {
    s3AccessKey = var.azure_storage_account_name
    s3SecretKey = var.azure_storage_account_key
  }

  type = "Opaque"
}

# Install GoodData.CN
resource "helm_release" "gooddata_cn" {
  name       = "gooddata-cn"
  repository = "https://charts.gooddata.com/"
  chart      = "gooddata-cn"
  version    = var.helm_gdcn_version
  namespace  = kubernetes_namespace.gdcn.metadata[0].name

  # Load your existing customized‑values‑gdcn.yaml on disk for brevity.
  values = [
    <<-EOF
replicaCount: "${var.gdcn_replica_count}"

deployVisualExporter: false
deployPostgresHA: false

metadataApi:
  encryptor:
    existingSecret: "${kubernetes_secret.gdcn_encryption.metadata[0].name}"

license:
  existingSecret: "${kubernetes_secret.gdcn_license.metadata[0].name}"

ingress:
  lbProtocol: https
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt"

dex:
  config:
    database:
      sslMode: require
    web:
      allowedOrigins:
        - "${local.gdcn_org_hostname}"
  ingress:
    authHost: "${local.auth_hostname}"
    annotations:
      cert-manager.io/cluster-issuer: "letsencrypt"
    tls:
      authSecretName: gooddata-cn-auth-tls

service:
  postgres:
    host: "${var.db_hostname}"
    port: 5432
    username: "${var.db_username}"
    password: "${var.db_password}"
    database: "${var.db_name}"

# Container image cache configuration
image:
  repositoryPrefix: ${var.registry_dockerio}/gooddata

## For all Bitnami charts
global:
  imageRegistry: ${var.registry_dockerio}
  security:
    # Bypasses checks since we're using the cache
    allowInsecureImages: true

redis-ha:
  image:
    repository: ${var.registry_dockerio}/library/redis
  exporter:
    image: ${var.registry_quayio}/oliver006/redis_exporter
EOF
    ,

    <<-EOF
# GoodData.CN tiny size profile
afmExecApi:
  jvmOptions: -Xmx880M -XX:MaxMetaspaceSize=256M -XX:MaxDirectMemorySize=96M
  resources:
    limits:
      cpu: 1000m
      memory: 1400Mi
    requests:
      cpu: 200m
      memory: 1400Mi
analyticalDesigner:
  resources:
    limits:
      cpu: 200m
      memory: 45Mi
    requests:
      cpu: 20m
      memory: 15Mi
apiDocs:
  resources:
    limits:
      cpu: 200m
      memory: 45Mi
    requests:
      cpu: 20m
      memory: 15Mi
apiGateway:
  jvmOptions: -Xmx225M -XX:MaxMetaspaceSize=100M -XX:MaxDirectMemorySize=512M
  resources:
    limits:
      cpu: 500m
      memory: 1Gi
    requests:
      cpu: 100m
      memory: 1Gi
authService:
  jvmOptions: -Xmx220M -XX:MaxMetaspaceSize=160M -XX:MaxDirectMemorySize=32M
  resources:
    limits:
      cpu: 500m
      memory: 716Mi
    requests:
      cpu: 100m
      memory: 716Mi
calcique:
  jvmOptions: -Xmx850M -XX:MaxMetaspaceSize=256M -XX:MaxDirectMemorySize=650M
  resources:
    limits:
      cpu: 1000m
      memory: 2200Mi
    requests:
      cpu: 200m
      memory: 2200Mi
dashboards:
  resources:
    limits:
      cpu: 200m
      memory: 45Mi
    requests:
      cpu: 20m
      memory: 15Mi
exportController:
  jvmOptions: -Xmx800M -XX:MaxMetaspaceSize=192M -XX:MaxDirectMemorySize=128M
  resources:
    limits:
      cpu: 500m
      memory: 1024Mi
    requests:
      cpu: 100m
      memory: 700Mi
homeUi:
  resources:
    limits:
      cpu: 200m
      memory: 45Mi
    requests:
      cpu: 20m
      memory: 15Mi
ldmModeler:
  resources:
    limits:
      cpu: 200m
      memory: 60Mi
    requests:
      cpu: 20m
      memory: 15Mi
measureEditor:
  resources:
    limits:
      cpu: 200m
      memory: 45Mi
    requests:
      cpu: 20m
      memory: 15Mi
metadataApi:
  jvmOptions: -Xmx2500M -XX:MaxMetaspaceSize=256M -XX:MaxDirectMemorySize=96M -XX:ActiveProcessorCount=6
    -Dkotlinx.coroutines.io.parallelism=16
  resources:
    limits:
      cpu: 2000m
      memory: 2600Mi
    requests:
      cpu: 750m
      memory: 1600Mi
organizationController:
  resources:
    limits:
      cpu: 200m
      memory: 256Mi
    requests:
      cpu: 50m
      memory: 170Mi
pdfStaplerService:
  jvmOptions: -Xmx800M -XX:MaxMetaspaceSize=128M -XX:MaxDirectMemorySize=32M
  resources:
    limits:
      cpu: 500m
      memory: 1500Mi
    requests:
      cpu: 100m
      memory: 620Mi
quiver:
  concurrentPutRequests: 16
  s3DurableStorage:
    durableS3WritesInProgress: 16%{if var.azure_storage_account_name != ""}
    # Azure Blob Storage configuration (S3-compatible)
    s3Bucket: "${var.azure_storage_container_cache}"
    s3BucketPrefix: "cache/"
    s3Region: "${var.azure_region}"
    s3AccessKey: "${var.azure_storage_account_name}"
    s3SecretKey: "${var.azure_storage_account_key}"
    s3Endpoint: "${var.azure_storage_endpoint}"
    s3ForcePathStyle: true
    s3UseSSL: true
    s3VerifySSL: false
    authType: "aws_tokens"%{endif}
  resources:
    cache:
      limits:
        cpu: 750m
        memory: 1456Mi
      requests:
        cpu: 150m
        memory: 1456Mi
    xtab:
      limits:
        cpu: 1000m
        memory: 700Mi
      requests:
        cpu: 250m
        memory: 700Mi
redis-ha:
  configmapTest:
    resources:
      limits:
        cpu: 50m
        memory: 40Mi
      requests:
        cpu: 20m
        memory: 40Mi
  exporter:
    resources:
      limits:
        cpu: 150m
        memory: 20Mi
      requests:
        cpu: 20m
        memory: 20Mi
  redis:
    config:
      maxmemory: 2900m
    resources:
      limits:
        cpu: 1500m
        memory: 2800Mi
      requests:
        cpu: 700m
        memory: 1800Mi
  sentinel:
    resources:
      limits:
        cpu: 100m
        memory: 35Mi
      requests:
        cpu: 50m
        memory: 35Mi
resultCache:
  jvmOptions: -Xmx2000M -XX:MaxMetaspaceSize=384M -XX:MaxDirectMemorySize=384M
  resources:
    limits:
      cpu: 700m
      memory: 3200Mi
    requests:
      cpu: 200m
      memory: 2200Mi
  pulsar:
    invalidation:
      enabled: true
scanModel:
  jvmOptions: -Xmx220M -XX:MaxMetaspaceSize=160M -XX:MaxDirectMemorySize=32M
  resources:
    limits:
      cpu: 500m
      memory: 600Mi
    requests:
      cpu: 100m
      memory: 600Mi
sqlExecutor:
  jvmOptions: -Xmx1800M -XX:MaxMetaspaceSize=256M -XX:MaxDirectMemorySize=256M
    -XX:ActiveProcessorCount=6
  resources:
    limits:
      cpu: 500m
      memory: 2800Mi
    requests:
      cpu: 100m
      memory: 1800Mi
tabularExporter:
  resources:
    limits:
      cpu: 400m
      memory: 750Mi
    requests:
      cpu: 100m
      memory: 750Mi
visualExporterChromium:
  resources:
    limits:
      cpu: 1200m
      memory: 3Gi
    requests:
      cpu: 200m
      memory: 3Gi
visualExporterProxy:
  resources:
    limits:
      cpu: 300m
      memory: 100Mi
    requests:
      cpu: 100m
      memory: 50Mi
visualExporterService:
  extraEnvVars:
    - name: SERVER_TOMCAT_THREADS_MAX
      value: "2"
    - name: SERVER_TOMCAT_ACCEPTCOUNT
      value: "500"
  jvmOptions: -Xmx432M -XX:MaxMetaspaceSize=192M -XX:MaxDirectMemorySize=32M
  resources:
    limits:
      cpu: 1000m
      memory: 1280Mi
    requests:
      cpu: 500m
      memory: 640Mi
webComponents:
  resources:
    limits:
      cpu: 200m
      memory: 45Mi
    requests:
      cpu: 20m
      memory: 15Mi
exportBuilder:
  # Chromium in standalone container within export-builder pod
  # export-builder connects to Chromium using Chrome DevTools Protocol (CDP)
  playwright:
    browser:
      type: "cdp"
  # These settings must be aligned with resource.limits.memory value
  # The minimum memory limit in MeBiBytes is (codecachesize+Xmx+metaspace+175)*1.024
  jvmOptions: -XX:ReservedCodeCacheSize=60M -Xmx1500M -XX:MaxMetaspaceSize=210M -XX:MaxDirectMemorySize=128M
  resources:
    limits:
      cpu: 2000m
      memory: 2000Mi
    requests:
      cpu: 200m
      memory: 550Mi
apiGw:
  resources:
    limits:
      cpu: 1400m
      memory: 1000Mi
    requests:
      cpu: 280m
      memory: 400Mi
  # -- Custom JVM options
  # These settings must be aligned with resource.limits.memory value
  jvmOptions: "-Xms280m -Xmx800m -XX:ActiveProcessorCount=2"
EOF
  ]

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
