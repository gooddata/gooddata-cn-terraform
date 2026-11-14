# Required only when enable_ai_lake is true (AI Lake is AWS-only); null otherwise.
variable "ai_lake_size_profile" {
  type    = string
  default = null
}

variable "auth_hostname" { type = string }

variable "aws_region" {
  type    = string
  default = ""
}

variable "azure_datasource_fs_container" {
  type    = string
  default = ""
}

variable "azure_exports_container" {
  type    = string
  default = ""
}

variable "azure_geo_collections_container" {
  description = "ABS container holding the geo collections used by geo charts."
  type        = string
  default     = ""
}

variable "azure_quiver_container" {
  type    = string
  default = ""
}

variable "azure_storage_account_name" {
  type    = string
  default = ""
}

variable "azure_uami_client_id" {
  type    = string
  default = ""
}

variable "cloud" { type = string }

variable "db_ca_cert" {
  description = "PEM CA certificate of the PostgreSQL server certificate (no key). Used only when db_ca_cert_enabled is true. The value may be unknown at plan time."
  type        = string
  default     = ""
}

variable "db_ca_cert_enabled" {
  description = "Create the postgres-ca-cert Secret from db_ca_cert and point gen-ai and the services' PostgreSQL (sslMode verify-full) at it. Must be known at plan time (do not derive it from db_ca_cert)."
  type        = bool
  default     = false
}

variable "db_hostname" { type = string }

variable "db_password" {
  type      = string
  sensitive = true
}

variable "db_username" { type = string }

variable "deployment_name" { type = string }

variable "dex_ingress_annotations_override" {
  type    = map(string)
  default = {}
}

variable "enable_ai_features" { type = bool }

variable "enable_experimental_features" { type = bool }

variable "enable_image_cache" { type = bool }

variable "enable_llm_observability" {
  description = "Enable self-hosted Langfuse LLM observability and wire the GoodData.CN gen-ai services to it"
  type        = bool
  default     = false

  validation {
    condition     = var.enable_llm_observability ? var.enable_ai_features : true
    error_message = "enable_llm_observability requires enable_ai_features = true; the gen-ai services are what emit the traces."
  }
}

variable "enable_observability" {
  description = "Enable observability stack (Prometheus, Loki, Tempo, Grafana)"
  type        = bool
  default     = false
}

variable "enable_ai_lake" {
  description = "Enable AI lake services for analytics query acceleration (AWS only)"
  type        = bool
  default     = false
}

variable "fast_storage_class" {
  description = "StorageClass for latency-sensitive GoodData.CN PVCs (etcd today). Falls back to gdcn_storage_class when empty."
  type        = string
  default     = ""
}

variable "s3_tables_bucket_arn" {
  description = "ARN of the AWS S3 Tables bucket used by AI Lake."
  type        = string
  default     = ""
}

variable "ailake_role_arn" {
  description = "ARN of the IAM role assumed by AI Lake for data access."
  type        = string
  default     = ""
}

variable "glue_etl_role_arn" {
  description = "ARN of the IAM role used by Glue ETL jobs created for AI Lake."
  type        = string
  default     = ""
}

variable "starrocks_s3_tables_iam_user_arn" {
  description = "ARN of the IAM user used by AI Lake to access AWS S3 Tables."
  type        = string
  default     = ""
}

variable "starrocks_admin_password_secret_name" {
  description = "Kubernetes secret name in the GoodData.CN namespace that stores STARROCKS_ADMIN_PASSWORD."
  type        = string
  default     = ""
}

variable "starrocks_admin_password_secret_key" {
  description = "Secret key used to read STARROCKS_ADMIN_PASSWORD from starrocks_admin_password_secret_name."
  type        = string
  default     = "STARROCKS_ADMIN_PASSWORD"
}

variable "gdcn_irsa_role_arn" {
  type    = string
  default = ""
}

variable "gdcn_license_key" {
  type      = string
  sensitive = true
}

variable "gdcn_namespace" {
  type    = string
  default = "gooddata-cn"
}

variable "gdcn_orgs" {
  type = list(object({
    admin_group = string
    admin_user  = string
    hostname    = string
    id          = string
    name        = string
  }))
}

variable "geo_aws_location_region" {
  description = "AWS region serving Amazon Location Service basemap tiles. Falls back to aws_region when empty."
  type        = string
  default     = ""
}

variable "geo_basemap_provider" {
  description = "Basemap provider backing geo charts: \"awslocation\", \"mapbox\", \"protomaps\" (self-contained, in-cluster) or \"none\"."
  type        = string
  default     = "none"
}

variable "geo_protomaps_image" {
  description = "Image of the in-cluster basemap server (gdc-nas tools/basemap-image), repository:tag[@digest]. Required when geo_basemap_provider is \"protomaps\"."
  type        = string
  default     = ""
}

variable "geo_protomaps_source_url" {
  description = "PMTiles archive that the extract Job cuts to geo_protomaps_bbox and geo_protomaps_max_zoom: a Protomaps daily build (https://build.protomaps.com/YYYYMMDD.pmtiles; daily builds are removed after some days) or a mirror on an internal http(s):// or s3:// URL for air-gapped installs. No default: daily builds expire, so set a current build or a mirror. Required, unless geo_protomaps_existing_claim is set, when geo_basemap_provider is \"protomaps\". Empty: no Job, the PVC must already hold basemap.pmtiles."
  type        = string
  default     = ""
}

variable "geo_protomaps_bbox" {
  description = "Area of the extract, \"min_lon,min_lat,max_lon,max_lat\". Default: the contiguous United States. Empty: the whole source."
  type        = string
  default     = "-125.0,24.0,-66.5,49.5"
}

variable "geo_protomaps_max_zoom" {
  description = "Highest zoom level of the extract (0-15). MapLibre scales the last level up. Each level adds about 3x the size."
  type        = number
  default     = 10

  validation {
    condition     = var.geo_protomaps_max_zoom >= 0 && var.geo_protomaps_max_zoom <= 15
    error_message = "geo_protomaps_max_zoom must be 0-15."
  }
}

variable "geo_protomaps_storage_size" {
  description = "Size of the basemap PVC. Must hold the extract (contiguous US: z10 about 390 MB, see README)."
  type        = string
  default     = "10Gi"
}

variable "geo_protomaps_existing_claim" {
  description = "Existing PVC in the GoodData.CN namespace that holds basemap.pmtiles (customer-provided file, for example for air-gapped installs). Set it to skip the PVC and the extract Job."
  type        = string
  default     = ""
}

variable "geo_mapbox_token" {
  description = "Mapbox access token used when geo_basemap_provider is \"mapbox\"."
  type        = string
  sensitive   = true
  default     = ""
}

variable "enable_gdcn_autoscaling" {
  description = "Enable KEDA autoscaling for GoodData.CN services."
  type        = bool
  default     = false
}

variable "helm_cert_manager_version" { type = string }

variable "helm_clickhouse_operator_version" { type = string }

variable "helm_gdcn_version" { type = string }

variable "helm_keda_version" {
  description = "Version of the KEDA Helm chart from dhi.io (dhi.io/keda-chart), for example 2.21.0."
  type        = string
  # renovate: datasource=docker depName=dhi.io/keda-chart
  default = "2.21.0"
}

variable "helm_grafana_version" { type = string }

variable "dhi_access_token" {
  type      = string
  sensitive = true
}

variable "dhi_username" {
  type = string
}

variable "helm_istio_version" { type = string }

variable "helm_langfuse_version" { type = string }

variable "helm_loki_version" { type = string }

variable "helm_kube_prometheus_stack_version" { type = string }

variable "helm_promtail_version" { type = string }

variable "helm_pulsar_version" { type = string }

variable "helm_starrocks_version" {
  type    = string
  default = ""
}

variable "helm_tempo_version" { type = string }

variable "helm_traefik_version" { type = string }

variable "ingress_annotations_override" {
  type    = map(string)
  default = {}
}

variable "ingress_behind_l7" { type = bool }

variable "ingress_controller" {
  type = string

  validation {
    condition     = contains(["alb", "traefik", "istio_gateway"], var.ingress_controller)
    error_message = "ingress_controller must be one of: \"alb\", \"traefik\", \"istio_gateway\"."
  }
}

# GoodData internal use only: install an unreleased build instead of the public chart.
# Empty internal_registry_server disables both the pull secret and the chart repo
# login, so a private internal_chart_repository needs it set even for public images.
# An ECR internal_registry_server mints its own token and ignores username/password.
variable "internal_chart_repository" {
  type    = string
  default = "https://charts.gooddata.com/"
}

variable "internal_registry_aws_profile" {
  type    = string
  default = ""
}

variable "internal_registry_password" {
  type      = string
  sensitive = true
  default   = ""
}

variable "internal_registry_server" {
  type    = string
  default = ""
}

variable "internal_registry_username" {
  type    = string
  default = ""
}

variable "langfuse_admin_email" {
  description = "Email of the bootstrap Langfuse admin"
  type        = string
  default     = ""

  validation {
    condition     = var.enable_llm_observability ? length(trimspace(var.langfuse_admin_email)) > 0 : true
    error_message = "langfuse_admin_email must be provided when enable_llm_observability is true."
  }
}

variable "langfuse_s3_access_key_id" {
  description = "Access key ID for the Langfuse bucket (Azure: the storage account name). Empty falls back to the pod's ambient credentials."
  type        = string
  default     = ""
  sensitive   = true
}

variable "langfuse_s3_bucket" {
  description = "Object-storage bucket (Azure: container) for Langfuse events, media and batch exports"
  type        = string
  default     = ""

  validation {
    condition     = var.enable_llm_observability ? length(trimspace(var.langfuse_s3_bucket)) > 0 : true
    error_message = "langfuse_s3_bucket must be provided when enable_llm_observability is true."
  }
}

variable "langfuse_s3_endpoint" {
  description = "Endpoint URL for the Langfuse bucket. Empty uses the provider default (AWS S3)."
  type        = string
  default     = ""
}

variable "langfuse_s3_force_path_style" {
  description = "Force path-style S3 requests, required by SeaweedFS."
  type        = bool
  default     = false
}

variable "langfuse_s3_region" {
  description = "Region of the Langfuse bucket. Ignored by Azure Blob."
  type        = string
  default     = ""
}

variable "langfuse_s3_secret_access_key" {
  description = "Secret access key for the Langfuse bucket (Azure: the storage account key). Empty falls back to the pod's ambient credentials."
  type        = string
  default     = ""
  sensitive   = true
}

variable "langfuse_s3_storage_provider" {
  description = "Blob-storage backend Langfuse talks to: s3 (any S3-compatible store) or azure (native Blob, shared-key auth only)."
  type        = string
  default     = "s3"

  validation {
    condition     = contains(["s3", "azure"], var.langfuse_s3_storage_provider)
    error_message = "langfuse_s3_storage_provider must be one of: s3, azure."
  }
}

variable "langfuse_service_account_annotations" {
  description = "Annotations on the Langfuse ServiceAccount for object-storage auth (AWS IRSA role-arn). Empty on stores that use static keys."
  type        = map(string)
  default     = {}
}

variable "langfuse_tracing_environment" {
  description = "Langfuse tracing environment reported by the GoodData.CN gen-ai services. Empty keeps the chart default."
  type        = string
  default     = "dev"
}

variable "letsencrypt_email" { type = string }

variable "llm_observability_hostname" {
  description = "Hostname for the Langfuse UI"
  type        = string
  default     = ""

  validation {
    condition     = var.enable_llm_observability ? length(trimspace(var.llm_observability_hostname)) > 0 : true
    error_message = "llm_observability_hostname must be provided when enable_llm_observability is true."
  }
}

variable "local_s3_access_key" {
  description = "S3 access key for local S3-compatible storage."
  type        = string
  default     = ""
  sensitive   = true
}

variable "local_s3_datasource_fs_bucket" {
  description = "Bucket name used for Quiver datasource FS (CSV uploads) in local S3-compatible storage."
  type        = string
  default     = ""
}

variable "local_s3_endpoint_override" {
  description = "S3 endpoint override URL (with scheme) for local S3-compatible storage."
  type        = string
  default     = ""
}

variable "local_s3_exports_bucket" {
  description = "Bucket name used for exports in local S3-compatible storage."
  type        = string
  default     = ""
}

variable "local_s3_geo_collections_bucket" {
  description = "Bucket holding the geo collections used by geo charts in local S3-compatible storage."
  type        = string
  default     = ""
}

variable "local_s3_quiver_cache_bucket" {
  description = "Bucket name used for Quiver durable cache in local S3-compatible storage."
  type        = string
  default     = ""
}

variable "local_s3_region" {
  description = "S3 region value for local S3-compatible storage."
  type        = string
  default     = ""
}

variable "local_s3_secret_key" {
  description = "S3 secret key for local S3-compatible storage."
  type        = string
  default     = ""
  sensitive   = true
}

variable "loki_retention_period" {
  description = "Loki log retention period (Go duration; must be a multiple of 24h, e.g. 168h = 7 days). Enables the compactor retention loop."
  type        = string
  default     = "168h"
}

variable "observability_hostname" {
  description = "Hostname for Grafana"
  type        = string
  default     = ""

  validation {
    condition     = var.enable_observability ? length(trimspace(var.observability_hostname)) > 0 : true
    error_message = "observability_hostname must be provided when enable_observability is true."
  }
}

variable "prometheus_retention_period" {
  description = "Prometheus metrics retention period (e.g. 168h = 7 days)."
  type        = string
  default     = "168h"
}

variable "registry_dockerio" { type = string }

variable "s3_datasource_fs_bucket_id" {
  type    = string
  default = ""
}

variable "s3_exports_bucket_id" {
  type    = string
  default = ""
}

variable "s3_geo_collections_bucket_id" {
  description = "S3 bucket holding the geo collections used by geo charts."
  type        = string
  default     = ""
}

variable "s3_quiver_cache_bucket_id" {
  type    = string
  default = ""
}

variable "starrocks_s3_bucket_id" {
  type    = string
  default = ""
}

variable "ingress_replicas" { type = number }

# Workload size selectors, resolved by each env's size-profiles.tf.
variable "gdcn_size" {
  type = string
  validation {
    condition     = contains(local.workload_size_tiers, var.gdcn_size)
    error_message = "gdcn_size must be one of: ${join(", ", local.workload_size_tiers)} (fold prod-xl to prod-large in the env's size-profiles.tf)."
  }
}

variable "gdcn_storage_class" {
  description = "Kubernetes StorageClass for GoodData.CN chart PVCs (redis-ha, qdrant, and etcd when fast_storage_class is unset). Empty string leaves them on the cluster default class."
  type        = string
  default     = ""
}

variable "observability_size" {
  type = string
  validation {
    condition     = contains(local.workload_size_tiers, var.observability_size)
    error_message = "observability_size must be one of: ${join(", ", local.workload_size_tiers)} (fold prod-xl to prod-large in the env's size-profiles.tf)."
  }
}

variable "pulsar_size" {
  type = string
  validation {
    condition     = contains(local.workload_size_tiers, var.pulsar_size)
    error_message = "pulsar_size must be one of: ${join(", ", local.workload_size_tiers)} (fold prod-xl to prod-large in the env's size-profiles.tf)."
  }
}

variable "starrocks_cn_image_tag" {
  type    = string
  default = "4.0.6"
}

variable "starrocks_s3_tables_access_key_id" {
  type      = string
  default   = ""
  sensitive = true
}

variable "starrocks_s3_tables_secret_access_key" {
  type      = string
  default   = ""
  sensitive = true
}

variable "starrocks_s3_tables_bucket_name" {
  type    = string
  default = ""
}

variable "aws_account_id" {
  type    = string
  default = ""
}

variable "starrocks_fe_image_tag" {
  type    = string
  default = "4.0.6"
}

variable "starrocks_irsa_role_arn" {
  type    = string
  default = ""
}

variable "tempo_retention_period" {
  description = "Tempo trace retention period (Go duration, e.g. 168h = 7 days). Sets the block-storage compactor retention."
  type        = string
  default     = "168h"
}

variable "tls_mode" { type = string }

variable "istio_gateway_fips_tls" {
  description = "Restrict the Istio ingress gateway TLS to FIPS-approved settings: TLS 1.2 minimum, ECDHE AES-GCM cipher suites for TLS 1.2, and ECDH curves P-256 and P-384. Only used when ingress_controller = \"istio_gateway\". This does not make Envoy FIPS-validated."
  type        = bool
  default     = false
}

variable "gdcn_chart_path" {
  description = "Path to a local gooddata-cn chart directory. When set, it replaces the chart repository and version (helm_gdcn_version is then used only for the version checks)."
  type        = string
  default     = ""
}

variable "gdcn_helm_extra_values" {
  description = "Additional Helm values YAML string appended to the gooddata-cn chart values. Use to override sub-chart settings not exposed as Terraform variables."
  type        = string
  default     = ""
}

variable "gdcn_helm_extra_values_files" {
  description = "Paths to Helm values files applied to the gooddata-cn chart after gdcn_helm_extra_values, in list order. The file contents become part of the Terraform plan and state (the Helm release values): do not put secrets in them."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for f in var.gdcn_helm_extra_values_files : fileexists(f)])
    error_message = "Every path in gdcn_helm_extra_values_files must be an existing file (paths are relative to the directory where Terraform runs)."
  }
}

# --- Hardening (see hardening.tf) -------------------------------------------

variable "gdcn_hardened" {
  description = "Turn on the hardened GoodData.CN profile: restricted pod security (non-root, read-only root filesystem) for the chart and its redis-ha and qdrant subcharts. Restarts all pods; the first start after the change re-owns existing volumes (fsGroup)."
  type        = bool
  default     = false
}

variable "gdcn_deploy_dex" {
  description = "Deploy the bundled Dex IdP (deployDexIdP). Set false only after every organization uses an external OIDC IdP."
  type        = bool
  default     = true
}

variable "gdcn_embedding_origins" {
  description = "Origins allowed to exchange postMessages with embedded dashboards (settings.embeddingOrigins). null keeps the chart default ['*']; [] allows none. Ignored by charts that do not know the key (4.15.1 and older)."
  type        = list(string)
  default     = null
}

# Values for GoodData.CN releases after 4.15.1. Each attribute is null by
# default and is then not rendered, so the current chart is unaffected.
variable "gdcn_hardening_next_release" {
  description = "Hardening values that need a GoodData.CN release after 4.15.1 (needs CN next release). Null attributes are not rendered."
  type = object({
    db_ssl_mode = optional(string)
    db_ssl_root_cert = optional(object({
      secret_name = string
      key         = optional(string, "ca.crt")
    }))
    fips_mode                   = optional(string)
    fips_allow_non_fips_host    = optional(bool)
    aws_use_fips_endpoint       = optional(bool)
    export_egress_mode          = optional(string)
    export_egress_allowed_hosts = optional(list(string))
  })
  default = {}

  validation {
    condition = (
      contains(["disable", "allow", "prefer", "require", "verify-ca", "verify-full"], coalesce(var.gdcn_hardening_next_release.db_ssl_mode, "verify-full")) &&
      contains(["compatible", "strict"], coalesce(var.gdcn_hardening_next_release.fips_mode, "strict")) &&
      contains(["open", "allowlist"], coalesce(var.gdcn_hardening_next_release.export_egress_mode, "allowlist"))
    )
    error_message = "db_ssl_mode must be a libpq sslmode, fips_mode must be compatible or strict, export_egress_mode must be open or allowlist."
  }
}

# --- Observability object storage (Loki/Tempo) -----------------------------
# When set, Loki/Tempo store chunks/index/trace-blocks in object storage
# (Azure Blob / S3 / SeaweedFS) instead of a large local PVC. Retention then
# lives in the bucket; the pods keep only a small fixed WAL PVC (obs_wal_disk).
# Built per-cloud and passed in; null => legacy filesystem behaviour.

variable "loki_objstore" {
  description = "Loki object-storage config: { object_store = \"azure\"|\"s3\", storage = <loki.storage block> }. Null => filesystem."
  type        = any
  default     = null
}

variable "tempo_objstore" {
  description = "Tempo trace object-storage config (the storage.trace block: backend + backend-specific block). Null => filesystem."
  type        = any
  default     = null
}

variable "aws_fips_endpoints" {
  description = "AWS only. true sets the chart value global.aws.useFipsEndpoint (every GoodData container calls the AWS FIPS endpoints) and writes the S3 FIPS host s3-fips.<region>.amazonaws.com in the exports URL. Must be false when aws_s3_endpoint is set."
  type        = bool
  default     = false
}

variable "aws_s3_endpoint" {
  description = "AWS only. Explicit S3 endpoint URL (https://host[:port]) for the GoodData.CN storage values (exports, Quiver cache, data source files, geo collections and the map ingestion job) and StarRocks. Empty keeps the AWS default endpoint. Set it only with aws_fips_endpoints = false: the chart refuses an explicit endpoint together with global.aws.useFipsEndpoint."
  type        = string
  default     = ""
  validation {
    condition     = var.aws_s3_endpoint == "" || can(regex("^https?://", var.aws_s3_endpoint))
    error_message = "aws_s3_endpoint must be empty or a URL with scheme (https://host[:port])."
  }
  validation {
    condition     = var.aws_s3_endpoint == "" || !var.aws_fips_endpoints
    error_message = "aws_s3_endpoint and aws_fips_endpoints cannot be used together: the AWS SDKs refuse a custom endpoint together with AWS_USE_FIPS_ENDPOINT. Put the FIPS host in aws_s3_endpoint and set aws_fips_endpoints = false."
  }
}

variable "azure_storage_endpoint_suffix" {
  description = "Azure only. Storage endpoint suffix of the Azure cloud: core.windows.net (public, default), core.usgovcloudapi.net (Azure Government), core.chinacloudapi.cn (Azure China). Blob hosts are <account>.blob.<suffix>, DFS hosts <account>.dfs.<suffix>. Used by GoodData.CN, Loki, Tempo and Langfuse."
  type        = string
  default     = "core.windows.net"
  validation {
    condition     = can(regex("^[a-z0-9-]+(\\.[a-z0-9-]+)+$", var.azure_storage_endpoint_suffix))
    error_message = "azure_storage_endpoint_suffix must be a domain without a leading dot, for example core.usgovcloudapi.net."
  }
}

variable "obs_extra_env" {
  description = "Extra environment variables for the Loki and Tempo containers, a list of { name, value }. AWS uses it for AWS_USE_FIPS_ENDPOINT."
  type        = list(object({ name = string, value = string }))
  default     = []
}

variable "obs_sa_annotations" {
  description = "ServiceAccount annotations applied to Loki/Tempo for object-storage auth (Azure workload-identity client-id / AWS IRSA role-arn)."
  type        = map(string)
  default     = {}
}

variable "obs_pod_labels" {
  description = "Pod labels applied to Loki/Tempo (e.g. azure.workload.identity/use=true to trigger the workload-identity webhook)."
  type        = map(string)
  default     = {}
}

variable "obs_wal_disk" {
  description = "Fixed WAL/scratch PVC size for Loki/Tempo when backed by object storage."
  type        = string
  default     = "10Gi"
}
