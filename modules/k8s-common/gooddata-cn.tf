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
# Control number of replicas for all GoodData.CN microservices
replicaCount: ${var.gdcn_replica_count}

# Disable Postgres HA
deployPostgresHA: false

# Enable Quiver filesystem data source (enables uploading CSVs)
deployQuiverDatasourceFs: true

# Use the created encryption secret
metadataApi:
  encryptor:
    existingSecret: "${kubernetes_secret.gdcn_encryption.metadata[0].name}"

# Use the created license secret
license:
  existingSecret: "${kubernetes_secret.gdcn_license.metadata[0].name}"

# Configure export controller to use S3 for exports
exportController:
  fileStorageBaseUrl: s3://s3.${var.aws_region}.amazonaws.com/${var.s3_exports_bucket_id}

# Configure quiver to use S3 for durable storage
quiver:
  durableStorageType: "S3"
  s3DurableStorage:
    s3Region: "${var.aws_region}"
    s3Bucket: "${var.s3_quiver_cache_bucket_id}"

  # Configure datasource filesystem to use S3
  datasourceFs:
    # Individual CSVs can be 200MB
    maxFileSize: 209715200
    # Total size of all CSVs can be 1GB
    maxFileSizeTotal: 1073741824
    storageType: "S3"

  s3DatasourceFsStorage:
    s3Region: "${var.aws_region}"
    s3Bucket: "${var.s3_datasource_fs_bucket_id}"

# Configure ingress to use HTTPS and Let's Encrypt
ingress:
  lbProtocol: https
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt"
    nginx.ingress.kubernetes.io/proxy-body-size: "200m"

# Configure Dex to allow the auth and org hostnames
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

# Use the external Postgres instance
service:
  postgres:
    host: "${var.db_hostname}"
    port: 5432
    username: "${var.db_username}"
    password: "${var.db_password}"

# Configure all GoodData microservices to use the container image cache (if configured)
image:
  repositoryPrefix: ${var.registry_dockerio}/gooddata

# Since we're (optionally) using the container image cache, bypass the insecure image check
global:
  imageRegistry: ${var.registry_dockerio}
  security:
    # Bypasses checks since we're using the cache
    allowInsecureImages: true

# Configure Redis HA to use the container image cache (if configured)
redis-ha:
  image:
    repository: ${var.registry_dockerio}/library/redis
  exporter:
    image: ${var.registry_quayio}/oliver006/redis_exporter
EOF
    ,

    <<-EOF
# Apply GoodData.CN "tiny" size profile
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
      memory: 3600Mi
    requests:
      cpu: 750m
      memory: 3600Mi
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
    durableS3WritesInProgress: 16
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
        memory: 3800Mi
      requests:
        cpu: 700m
        memory: 3800Mi
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
      memory: 3200Mi
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
      memory: 2800Mi
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
