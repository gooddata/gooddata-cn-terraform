###
# Deploy all Kubernetes resources to local k3d cluster
###

locals {
  # CloudNativePG (in-cluster) service name for a Cluster named "postgres"
  local_db_hostname = "postgres-rw.${module.k8s_local.postgres_namespace}.svc.cluster.local"

  local_db_username = "postgres"
}

resource "random_password" "local_postgres_password" {
  length  = 32
  special = true

  # Keep this friendly for:
  # - URL/CLI usage
  # - our bootstrap token format: "user:bootstrap:password"
  # (avoid ':' and whitespace)
  override_special = "_%@-"
}

module "k8s_local" {
  source = "../modules/k8s-local"

  providers = {
    kubernetes = kubernetes
    helm       = helm
    random     = random
    kubectl    = kubectl
    external   = external
  }

  enable_istio_injection = var.ingress_controller == "istio_gateway"
  helm_cnpg_version      = var.helm_cnpg_version
  db_username            = local.local_db_username
  db_password            = random_password.local_postgres_password.result

  depends_on = [
    null_resource.k3d_cluster,
  ]
}

module "k8s_common" {
  source = "../modules/k8s-common"

  providers = {
    kubernetes = kubernetes
    helm       = helm
    kubectl    = kubectl
    random     = random
    external   = external
  }

  deployment_name    = var.deployment_name
  gdcn_license_key   = var.gdcn_license_key
  gdcn_orgs          = var.gdcn_orgs
  size_profile       = var.size_profile
  cloud              = "local"
  ingress_controller = var.ingress_controller

  letsencrypt_email       = ""
  auth_hostname           = var.auth_hostname
  tls_mode                = var.tls_mode
  ingress_nginx_behind_l7 = var.ingress_nginx_behind_l7

  enable_ai_features = var.enable_ai_features
  enable_image_cache = false
  registry_dockerio  = var.registry_dockerio
  registry_quayio    = var.registry_quayio
  registry_k8sio     = var.registry_k8sio

  helm_cert_manager_version  = var.helm_cert_manager_version
  helm_gdcn_version          = var.helm_gdcn_version
  helm_istio_version         = var.helm_istio_version
  helm_pulsar_version        = var.helm_pulsar_version
  helm_ingress_nginx_version = var.helm_ingress_nginx_version
  helm_prometheus_version    = var.helm_prometheus_version
  helm_loki_version          = var.helm_loki_version
  helm_promtail_version      = var.helm_promtail_version
  helm_tempo_version         = var.helm_tempo_version
  helm_grafana_version       = var.helm_grafana_version

  enable_observability   = var.enable_observability
  observability_hostname = var.observability_hostname

  # Local MinIO-backed S3 (used for CSV upload storage via Quiver datasource FS)
  local_s3_endpoint_override    = module.k8s_local.minio_s3_endpoint
  local_s3_region               = module.k8s_local.minio_region
  local_s3_access_key           = module.k8s_local.minio_gdcn_access_key
  local_s3_secret_key           = module.k8s_local.minio_gdcn_secret_key
  local_s3_exports_bucket       = module.k8s_local.minio_bucket_exports
  local_s3_datasource_fs_bucket = module.k8s_local.minio_bucket_datasource_fs
  local_s3_quiver_cache_bucket  = module.k8s_local.minio_bucket_quiver_cache

  # Local DB provisioned in-cluster by modules/k8s-local
  db_hostname = local.local_db_hostname
  db_username = local.local_db_username
  db_password = random_password.local_postgres_password.result

  depends_on = [
    null_resource.k3d_cluster,
    module.k8s_local,
  ]
}

# Enforce STRICT mTLS for MinIO when Istio is active.
# Lives in the root module because the namespace is created by k8s-local
# while the Istio CRDs are installed by k8s-common.
# NOTE: Postgres is excluded — its binary wire protocol is incompatible with Envoy.

resource "kubectl_manifest" "peerauth_minio_strict" {
  count = var.ingress_controller == "istio_gateway" ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1beta1"
    kind       = "PeerAuthentication"
    metadata   = { name = "default", namespace = module.k8s_local.minio_namespace }
    spec       = { mtls = { mode = "STRICT" } }
  })

  depends_on = [module.k8s_common]
}
