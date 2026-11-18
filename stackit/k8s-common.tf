###
# Deploy all common Kubernetes resources
###

module "k8s_common" {
  source = "../modules/k8s-common"

  providers = {
    kubernetes = kubernetes
    helm       = helm
    kubectl    = kubectl
    random     = random
    external   = external
  }

  deployment_name        = var.deployment_name
  gdcn_namespace         = var.gdcn_namespace
  gdcn_license_key       = var.gdcn_license_key
  gdcn_orgs              = var.gdcn_orgs
  gdcn_helm_extra_values = var.gdcn_helm_extra_values
  ingress_replicas       = local.profile.ingress_replicas
  gdcn_size              = local.profile.gdcn_size
  gdcn_storage_class     = local.storage_class
  fast_storage_class     = local.fast_storage_class
  pulsar_size            = local.profile.pulsar_size
  observability_size     = local.profile.observability_size
  cloud                  = "stackit"
  ingress_controller     = var.ingress_controller

  letsencrypt_email = var.letsencrypt_email
  auth_hostname     = var.auth_hostname
  tls_mode          = var.tls_mode
  ingress_behind_l7 = var.ingress_behind_l7

  enable_ai_features           = var.enable_ai_features
  enable_experimental_features = var.enable_experimental_features
  enable_gdcn_autoscaling      = var.enable_gdcn_autoscaling
  # STACKIT has no Terraform-manageable container registry, so images come
  # straight from the configured registries.
  enable_image_cache = false
  registry_dockerio  = var.registry_dockerio
  registry_quayio    = var.registry_quayio
  registry_k8sio     = var.registry_k8sio

  helm_cert_manager_version          = var.helm_cert_manager_version
  helm_gdcn_version                  = var.helm_gdcn_version
  helm_istio_version                 = var.helm_istio_version
  helm_pulsar_version                = var.helm_pulsar_version
  helm_traefik_version               = var.helm_traefik_version
  helm_kube_prometheus_stack_version = var.helm_kube_prometheus_stack_version
  helm_loki_version                  = var.helm_loki_version
  helm_promtail_version              = var.helm_promtail_version
  helm_tempo_version                 = var.helm_tempo_version
  helm_grafana_version               = var.helm_grafana_version

  enable_observability        = var.enable_observability
  observability_hostname      = var.observability_hostname
  loki_retention_period       = var.loki_retention_period
  prometheus_retention_period = var.prometheus_retention_period
  tempo_retention_period      = var.tempo_retention_period

  db_hostname = local.db_hostname
  db_username = local.db_username
  db_password = local.db_password

  # Object storage is S3-compatible with static keys, so it reuses the generic-S3
  # values file.
  generic_s3 = {
    scheme                 = "https"
    endpoint_override      = local.s3_endpoint_url
    region                 = var.stackit_region
    access_key             = stackit_objectstorage_credential.main["gdcn"].access_key
    secret_key             = stackit_objectstorage_credential.main["gdcn"].secret_access_key
    exports_bucket         = local.bucket_names["exports"]
    quiver_cache_bucket    = local.bucket_names["quiver-cache"]
    datasource_fs_bucket   = local.bucket_names["quiver-datasource-fs"]
    geo_collections_bucket = try(local.bucket_names["geo-collections"], "")
  }
  geo_basemap_provider = var.geo_basemap_provider
  geo_mapbox_token     = var.geo_mapbox_token

  # Loki/Tempo use their own credentials group. Their S3 clients want a bare host,
  # while the GoodData.CN chart takes the full URL.
  loki_objstore = {
    object_store = "s3"
    storage = {
      type = "s3"
      # The SingleBinary chart references all three bucket names even with
      # ruler/admin features off; point them at the one loki bucket.
      bucketNames = {
        chunks = local.bucket_names["loki"]
        ruler  = local.bucket_names["loki"]
        admin  = local.bucket_names["loki"]
      }
      s3 = {
        endpoint         = local.s3_endpoint_host
        region           = var.stackit_region
        accessKeyId      = stackit_objectstorage_credential.main["observability"].access_key
        secretAccessKey  = stackit_objectstorage_credential.main["observability"].secret_access_key
        s3ForcePathStyle = true
      }
    }
  }
  tempo_objstore = {
    backend = "s3"
    s3 = {
      bucket         = local.bucket_names["tempo"]
      endpoint       = local.s3_endpoint_host
      region         = var.stackit_region
      access_key     = stackit_objectstorage_credential.main["observability"].access_key
      secret_key     = stackit_objectstorage_credential.main["observability"].secret_access_key
      forcepathstyle = true
    }
    wal = { path = "/var/tempo/wal" }
  }
  # No obs_sa_annotations / obs_pod_labels: object storage uses static keys, so
  # there is no workload identity to annotate.

  depends_on = [
    stackit_ske_cluster.main,
    # Pre-delete hooks still use object storage, so destroy must remove k8s_common
    # before the buckets.
    stackit_objectstorage_bucket.exports,
    stackit_objectstorage_bucket.buckets,
    stackit_objectstorage_credential.main,
    # The database user must exist before the chart bootstraps its schemas.
    stackit_postgresflex_user.gdcn,
  ]
}

output "auth_hostname" {
  description = "The hostname for Dex authentication ingress"
  value       = module.k8s_common.auth_hostname
}

output "enable_observability" {
  description = "Whether observability stack is enabled."
  value       = var.enable_observability
}

output "observability_hostname" {
  description = "Hostname used for Grafana ingress."
  value       = var.observability_hostname
}

output "org_domains" {
  description = "All GoodData.CN organization hostnames derived from gdcn_orgs"
  value       = module.k8s_common.org_domains
}

output "org_ids" {
  description = "List of organization IDs/DNS labels allowed by this deployment"
  value       = module.k8s_common.org_ids
}

# Read the LoadBalancer IP through the kubernetes provider, not a cloud CLI.
data "kubernetes_service_v1" "ingress_lb" {
  metadata {
    name      = var.ingress_controller == "traefik" ? "traefik" : "istio-ingress"
    namespace = var.ingress_controller == "traefik" ? "traefik" : "istio-ingress"
  }

  depends_on = [module.k8s_common]
}

locals {
  # May be empty early in provisioning, before yawol assigns an address.
  ingress_lb_ip = try(data.kubernetes_service_v1.ingress_lb.status[0].load_balancer[0].ingress[0].ip, "")
}

output "manual_dns_records" {
  description = "DNS records to create for STACKIT ingress. Empty until the load balancer has a public IP."
  value = local.ingress_lb_ip == "" ? [] : [
    for hostname in distinct(compact(concat(
      [module.k8s_common.auth_hostname],
      module.k8s_common.org_domains,
      var.enable_observability ? [trimspace(var.observability_hostname)] : []
      ))) : {
      hostname    = hostname
      record_type = "A"
      value       = local.ingress_lb_ip
    }
  ]
}
