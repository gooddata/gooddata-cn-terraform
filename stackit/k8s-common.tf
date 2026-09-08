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

  letsencrypt_email       = var.letsencrypt_email
  auth_hostname           = var.auth_hostname
  tls_mode                = var.tls_mode
  ingress_nginx_behind_l7 = var.ingress_nginx_behind_l7

  enable_ai_features           = var.enable_ai_features
  enable_experimental_features = var.enable_experimental_features
  # AI lake is AWS-only: its StarRocks shared-data storage config exists only in
  # the AWS values template, so enabling it elsewhere never brings StarRocks up.
  enable_ai_lake = false
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
  helm_ingress_nginx_version         = var.helm_ingress_nginx_version
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

  # STACKIT-specific storage configuration. Object storage is S3-compatible with
  # an endpoint override and static keys, so it shares the generic-S3 values file
  # with the local install rather than having its own.
  stackit_s3_endpoint_override    = local.s3_endpoint_url
  stackit_s3_region               = var.stackit_region
  stackit_s3_access_key           = stackit_objectstorage_credential.gdcn.access_key
  stackit_s3_secret_key           = stackit_objectstorage_credential.gdcn.secret_access_key
  stackit_s3_exports_bucket       = stackit_objectstorage_bucket.buckets["exports"].name
  stackit_s3_quiver_cache_bucket  = stackit_objectstorage_bucket.buckets["quiver-cache"].name
  stackit_s3_datasource_fs_bucket = stackit_objectstorage_bucket.buckets["quiver-datasource-fs"].name

  # Observability object storage: Loki + Tempo write to Object Storage (no big
  # PVC) using their own credentials group. Their S3 clients want a bare host,
  # while the GoodData.CN chart above takes the full URL.
  loki_objstore = {
    object_store = "s3"
    storage = {
      type = "s3"
      # The SingleBinary chart references all three bucket names even with
      # ruler/admin features off; point them at the one loki bucket.
      bucketNames = {
        chunks = stackit_objectstorage_bucket.buckets["loki"].name
        ruler  = stackit_objectstorage_bucket.buckets["loki"].name
        admin  = stackit_objectstorage_bucket.buckets["loki"].name
      }
      s3 = {
        endpoint         = local.s3_endpoint_host
        region           = var.stackit_region
        accessKeyId      = stackit_objectstorage_credential.observability.access_key
        secretAccessKey  = stackit_objectstorage_credential.observability.secret_access_key
        s3ForcePathStyle = true
      }
    }
  }
  tempo_objstore = {
    backend = "s3"
    s3 = {
      bucket         = stackit_objectstorage_bucket.buckets["tempo"].name
      endpoint       = local.s3_endpoint_host
      region         = var.stackit_region
      access_key     = stackit_objectstorage_credential.observability.access_key
      secret_key     = stackit_objectstorage_credential.observability.secret_access_key
      forcepathstyle = true
    }
    wal = { path = "/var/tempo/wal" }
  }
  # No obs_sa_annotations / obs_pod_labels: object storage uses static keys, so
  # there is no workload identity to annotate.

  depends_on = [
    stackit_ske_cluster.main,
    # Object storage must outlive the helm releases: pre-delete hooks still read
    # and write it, so listing these here makes destroy tear down k8s_common
    # first and the buckets after.
    stackit_objectstorage_bucket.buckets,
    stackit_objectstorage_credential.gdcn,
    stackit_objectstorage_credential.observability,
    # The database user must exist before the chart bootstraps its schemas.
    stackit_postgresflex_user.gdcn,
    # DNS must resolve before cert-manager issues its first Let's Encrypt cert;
    # a failed issuance backs off up to 32h. No-op unless dns_provider=stackit-dns.
    stackit_dns_zone.main,
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

# The kubernetes provider is already wired to the cluster, so the LoadBalancer IP
# is read directly instead of shelling out to a cloud CLI.
data "kubernetes_service_v1" "ingress_lb" {
  count = var.ingress_controller == "ingress-nginx" ? 1 : 0

  metadata {
    name      = "ingress-nginx-controller"
    namespace = "ingress-nginx"
  }

  depends_on = [module.k8s_common]
}

data "kubernetes_service_v1" "istio_ingress_lb" {
  count = var.ingress_controller == "istio_gateway" ? 1 : 0

  metadata {
    name      = "istio-ingress"
    namespace = "istio-ingress"
  }

  depends_on = [module.k8s_common]
}

locals {
  # May be empty early in provisioning, before yawol assigns an address.
  ingress_lb_ip       = try(data.kubernetes_service_v1.ingress_lb[0].status[0].load_balancer[0].ingress[0].ip, "")
  istio_ingress_lb_ip = try(data.kubernetes_service_v1.istio_ingress_lb[0].status[0].load_balancer[0].ingress[0].ip, "")
  resolved_lb_ip      = var.ingress_controller == "istio_gateway" ? local.istio_ingress_lb_ip : local.ingress_lb_ip
}

output "manual_dns_records" {
  description = "DNS records to create for STACKIT ingress. Empty when dns_provider = \"stackit-dns\" — the SKE DNS extension maintains the records automatically."
  value = local.external_dns_enabled || local.resolved_lb_ip == "" ? [] : [
    for hostname in distinct(compact(concat(
      [module.k8s_common.auth_hostname],
      module.k8s_common.org_domains,
      var.enable_observability ? [trimspace(var.observability_hostname)] : []
      ))) : {
      hostname    = hostname
      record_type = "A"
      value       = local.resolved_lb_ip
    }
  ]
}
