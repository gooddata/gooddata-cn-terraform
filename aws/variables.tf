variable "ai_lake_size_profile" {
  description = "AI Lake sizing profile. Required when enable_ai_lake is true; one of: dev, prod-small, prod-xl. Not derived from size_profile."
  type        = string
  default     = null
  validation {
    condition     = var.ai_lake_size_profile == null || contains(["dev", "prod-small", "prod-xl"], var.ai_lake_size_profile)
    error_message = "ai_lake_size_profile must be one of: dev, prod-small, prod-xl."
  }
  validation {
    condition     = !var.enable_ai_lake || var.ai_lake_size_profile != null
    error_message = "ai_lake_size_profile must be set when enable_ai_lake is true."
  }
}

variable "auth_hostname" {
  description = "Hostname for the default GoodData identity provider (Dex) ingress."
  type        = string
  validation {
    condition     = length(trimspace(var.auth_hostname)) > 0
    error_message = "auth_hostname must be provided."
  }
}

variable "aws_additional_tags" {
  description = "Map of additional tags to apply to all AWS resources"
  type        = map(string)
  default     = {}
}

variable "aws_profile_name" {
  description = "Name of AWS profile defined in ~/.aws/config to be used by Terraform."
  type        = string
}

variable "aws_region" {
  description = "AWS region to deploy resources to."
  type        = string
  default     = "us-east-2"
}

variable "deployment_name" {
  description = "Name prefix for all AWS resources."
  type        = string
  default     = "gooddata-cn"
  validation {
    condition     = can(regex("^[a-z](?:[a-z0-9-]*[a-z0-9])?$", var.deployment_name))
    error_message = "deployment_name must be lowercase, start with a letter, contain only letters, numbers, and hyphens, and must not end with a hyphen."
  }
}

variable "dns_provider" {
  description = "DNS management mode on AWS. Use route53 to enable ExternalDNS, or self-managed to manage DNS yourself."
  type        = string
  default     = "self-managed"
  validation {
    condition     = contains(["route53", "self-managed"], var.dns_provider)
    error_message = "dns_provider must be \"route53\" or \"self-managed\"."
  }
}

variable "dockerhub_access_token" {
  description = "Docker Hub access token (can be created in Settings > Personal Access Tokens)"
  type        = string
  default     = ""
  sensitive   = true
  validation {
    condition     = var.enable_image_cache ? length(var.dockerhub_access_token) > 0 : true
    error_message = "dockerhub_access_token must be provided when enable_image_cache is true."
  }
}

variable "dockerhub_username" {
  description = "Docker Hub username (used to pull images without hitting rate limits). Free account is enough."
  type        = string
  default     = ""
  sensitive   = true
  validation {
    condition     = var.enable_image_cache ? length(var.dockerhub_username) > 0 : true
    error_message = "dockerhub_username must be provided when enable_image_cache is true."
  }
}

variable "eks_ai_lake_node_types" {
  description = "EC2 instance types for the dedicated AI Lake node pool (taint workload=starrocks). If null, defaults to a preset chosen by ai_lake_size_profile."
  type        = list(string)
  default     = null
}

variable "eks_endpoint_private_access" {
  description = "Whether the EKS API server is reachable privately from within the VPC."
  type        = bool
  default     = false
}

variable "eks_endpoint_public_access" {
  description = "Whether the EKS API server is reachable publicly."
  type        = bool
  default     = true
}

variable "eks_endpoint_public_access_cidrs" {
  description = "CIDR blocks allowed to reach the public EKS endpoint when enabled."
  type        = list(string)
  default     = ["0.0.0.0/0"]
  validation {
    condition     = var.eks_endpoint_public_access ? length(var.eks_endpoint_public_access_cidrs) > 0 : true
    error_message = "Provide at least one CIDR when eks_endpoint_public_access is true."
  }
}

variable "eks_node_cpu_limit" {
  description = "Total vCPU ceiling for Karpenter-provisioned general workload nodes, applied as the general NodePool's spec.limits.cpu. Karpenter stops provisioning once exceeded. If null, chosen by size_profile."
  type        = number
  default     = null
}

variable "eks_node_cpu_max" {
  description = "Per-node vCPU cap for Karpenter-provisioned general workload nodes, applied as the general NodePool's karpenter.k8s.aws/instance-cpu Lt requirement. Bounds the size of any single workload node within the m category. If null, chosen by size_profile."
  type        = number
  default     = null
}

variable "eks_node_disk_size" {
  description = "Data volume size in GiB for every node's /dev/xvdb, on both the system node group and the Karpenter EC2NodeClass. Bottlerocket otherwise defaults to 20 GiB, which is below the ephemeral-storage some GoodData.CN pods request and leaves them unschedulable on every instance type."
  type        = number
  default     = 100
}

variable "eks_node_max_pods" {
  description = "Kubelet maxPods for every node, set on the Karpenter EC2NodeClass and in the system node group's Bottlerocket settings. Both otherwise derive it from the instance type's secondary-IP limits, which leaves VPC CNI prefix delegation inert. 110 is the AWS-recommended ceiling for instances under 30 vCPU."
  type        = number
  default     = 110
}

variable "eks_storage_class" {
  description = "Kubernetes StorageClass for GoodData.CN chart PVCs. If null, chosen by size_profile. Latency-sensitive PVCs use the fast class instead, which is not user-configurable."
  type        = string
  default     = null
}

variable "eks_version" {
  description = "Version of EKS to deploy."
  type        = string
  default     = "1.35"
}

variable "enable_ai_features" {
  description = "Enable AI features in the gooddata-cn chart (GenAI service, semantic search, chat, metadata sync, and Qdrant)."
  type        = bool
  default     = true
}

variable "enable_gdcn_autoscaling" {
  description = "Enable KEDA-based horizontal autoscaling for the GoodData.CN UI and core services."
  type        = bool
  default     = false

  validation {
    condition = !var.enable_gdcn_autoscaling || try(
      tonumber(split(".", var.helm_gdcn_version)[0]) > 4 ||
      (tonumber(split(".", var.helm_gdcn_version)[0]) == 4 && tonumber(split(".", var.helm_gdcn_version)[1]) >= 12),
    false)
    error_message = "Autoscaling requires helm_gdcn_version >= 4.12.0. Upgrade the chart, or set enable_gdcn_autoscaling = false."
  }
}

variable "enable_experimental_features" {
  description = "Enable experimental AI features in the gooddata-cn chart. These are subject to change and the set of features may evolve over time."
  type        = bool
  default     = false
}

variable "enable_image_cache" {
  description = "Enable image caching (ECR pull-through cache). If false, images are pulled from upstream registries directly."
  type        = bool
  default     = false
}

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
  description = "Enable AI Lake deployment for analytics query acceleration"
  type        = bool
  default     = false
}

variable "existing_private_subnet_ids" {
  description = "Private subnet IDs in the existing VPC (for EKS nodes and RDS). Required when existing_vpc_id is set. Must span at least 2 AZs."
  type        = list(string)
  default     = []
  validation {
    condition     = length(var.existing_private_subnet_ids) == 0 || length(var.existing_private_subnet_ids) >= 2
    error_message = "existing_private_subnet_ids must be empty or contain at least 2 entries."
  }
}

variable "existing_public_subnet_ids" {
  description = "Public subnet IDs in the existing VPC (for load balancers). Required when existing_vpc_id is set. Must span at least 2 AZs. Subnets must be tagged with kubernetes.io/role/elb=1 and kubernetes.io/cluster/<deployment_name>=shared for the AWS Load Balancer Controller."
  type        = list(string)
  default     = []
  validation {
    condition     = length(var.existing_public_subnet_ids) == 0 || length(var.existing_public_subnet_ids) >= 2
    error_message = "existing_public_subnet_ids must be empty or contain at least 2 entries."
  }
}

variable "existing_vpc_id" {
  description = "ID of an existing VPC to deploy into. Leave empty to create a new VPC. When set, existing_private_subnet_ids and existing_public_subnet_ids must also be provided."
  type        = string
  default     = ""
}

variable "fips_enabled" {
  description = "Prepare the AWS infrastructure for a FIPS 140 validation run: Bottlerocket FIPS AMIs, AWS FIPS service endpoints (provider, ECR registry host, in-cluster AWS clients), TLS-only RDS connections, Istio as the only allowed ingress (ingress_controller = \\\"istio_gateway\\\") and the FIPS Istio gateway TLS profile (istio_gateway_fips_tls). Requires a region with FIPS endpoints. The chart value global.aws.useFipsEndpoint is set too, so the GoodData.CN containers, Loki and Tempo call the AWS FIPS endpoints (S3, STS). This does not make the GoodData.CN containers FIPS-capable."
  type        = bool
  default     = false
  validation {
    condition     = !var.fips_enabled || contains(["us-east-1", "us-east-2", "us-west-1", "us-west-2"], var.aws_region)
    error_message = "fips_enabled = true requires a region with AWS FIPS endpoints: us-east-1, us-east-2, us-west-1 or us-west-2."
  }
  validation {
    condition     = !var.fips_enabled || var.ingress_controller == "istio_gateway"
    error_message = "fips_enabled = true requires ingress_controller = \"istio_gateway\" (also set tls_mode = \"letsencrypt\"). No other ingress controller is allowed."
  }
  validation {
    condition     = !var.fips_enabled || var.tls_mode == "letsencrypt"
    error_message = "fips_enabled = true requires tls_mode = \"letsencrypt\" (ACM with the ALB is not allowed under FIPS)."
  }
}

variable "s3_endpoint" {
  description = "Explicit S3 endpoint for every in-cluster S3 client: the GoodData.CN storage (exports, Quiver cache, data source files, geo collections), Loki, Tempo, Langfuse and StarRocks. A host (s3-fips.us-east-1.amazonaws.com) or a URL (https://host[:port]). Empty (default) keeps the AWS default endpoint; under fips_enabled the AWS SDKs then select the FIPS endpoints through AWS_USE_FIPS_ENDPOINT. Rule: a set endpoint is used as it is and AWS_USE_FIPS_ENDPOINT is not set for these clients (the AWS SDKs refuse both together), so give the FIPS host yourself when you need FIPS. Use it for a VPC endpoint, an S3-compatible store or another partition."
  type        = string
  default     = ""
  validation {
    condition     = var.s3_endpoint == "" || can(regex("^(https?://)?[A-Za-z0-9.-]+(:[0-9]+)?/?$", var.s3_endpoint))
    error_message = "s3_endpoint must be empty, a host[:port] or http(s)://host[:port]."
  }
}

variable "eks_node_arch" {
  description = "CPU architecture of all EKS nodes: \"amd64\" (AMD m-series) or \"arm64\" (Graviton m8g). With arm64, set eks_ai_lake_node_types to arm64 instance types when enable_ai_lake = true."
  type        = string
  default     = "amd64"
  validation {
    condition     = contains(["amd64", "arm64"], var.eks_node_arch)
    error_message = "eks_node_arch must be \"amd64\" or \"arm64\"."
  }
  validation {
    condition     = var.eks_node_arch != "arm64" || !var.enable_ai_lake || var.eks_ai_lake_node_types != null
    error_message = "eks_node_arch = \"arm64\" with enable_ai_lake = true requires eks_ai_lake_node_types to be set to arm64 instance types: the presets are x86 only."
  }
}

variable "karpenter_fips_ami_id" {
  description = "Pin the Bottlerocket FIPS AMI ID used by Karpenter nodes when fips_enabled = true. Empty reads the latest AMI from SSM at every plan, and a new ID rolls all Karpenter workload nodes."
  type        = string
  default     = ""
}

variable "istio_gateway_fips_tls" {
  description = "Restrict the Istio ingress gateway TLS to FIPS-approved settings: TLS 1.2 minimum, ECDHE AES-GCM cipher suites for TLS 1.2, and ECDH curves P-256 and P-384. Only used when ingress_controller = \"istio_gateway\". This does not make Envoy FIPS-validated."
  type        = bool
  default     = false
}

variable "gdcn_chart_path" {
  description = "Path to a local gooddata-cn chart directory. When set, it replaces the chart repository and version (set helm_gdcn_version to a value containing \"+\", such as 0.0.0+local, to skip the version checks)."
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

# Hardening: see the README section "Hardening".
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

variable "gdcn_license_key" {
  description = "GoodData.CN license key (provided by your GoodData contact)"
  type        = string
  sensitive   = true
}

variable "gdcn_namespace" {
  description = "Kubernetes namespace used for GoodData.CN resources (and service account)."
  type        = string
  default     = "gooddata-cn"
  validation {
    condition     = length(trimspace(var.gdcn_namespace)) > 0
    error_message = "gdcn_namespace must be provided."
  }
}

variable "gdcn_orgs" {
  description = "Organizations to manage as Organization custom resources. If empty, Terraform does not create any Organization objects."
  type = list(object({
    admin_group = string
    admin_user  = string
    hostname    = string
    id          = string
    name        = string
  }))
  default = []

  validation {
    condition = (
      length(distinct([for org in var.gdcn_orgs : trimspace(org.id)])) == length(var.gdcn_orgs) &&
      length(distinct([for org in var.gdcn_orgs : trimspace(org.hostname)])) == length(var.gdcn_orgs)
      ) && alltrue([
        for org in var.gdcn_orgs : (
          length(trimspace(org.id)) > 0 &&
          can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", trimspace(org.id))) &&
          length(trimspace(org.name)) > 0 &&
          length(trimspace(org.admin_user)) > 0 &&
          length(trimspace(org.admin_group)) > 0 &&
          length(trimspace(org.hostname)) > 0
        )
    ])
    error_message = "gdcn_orgs must have unique non-empty ids (lowercase DNS labels) and hostnames, and each org must set non-empty name, admin_user, admin_group, and hostname."
  }
}

variable "geo_aws_location_region" {
  description = "AWS region serving Amazon Location Service basemap tiles. Falls back to aws_region when empty."
  type        = string
  default     = ""
}

variable "geo_basemap_provider" {
  description = "Basemap provider backing geo charts: \"awslocation\" uses Amazon Location Service via IRSA (no FIPS endpoint outside us-gov-west-1), \"mapbox\" uses Mapbox with geo_mapbox_token, \"protomaps\" is SELF-CONTAINED: an in-cluster OpenStreetMap basemap with no external service at runtime, works air-gapped, tile traffic stays in the cluster/mesh; \"none\" turns geo charts off."
  type        = string
  default     = "none"

  validation {
    condition     = contains(["none", "awslocation", "mapbox", "protomaps"], var.geo_basemap_provider)
    error_message = "geo_basemap_provider must be one of: none, awslocation, mapbox, protomaps."
  }
}

variable "geo_protomaps_image" {
  description = "Image of the in-cluster basemap server (gdc-nas tools/basemap-image), repository:tag[@digest]. Required when geo_basemap_provider is \"protomaps\"."
  type        = string
  default     = ""
}

variable "geo_protomaps_source_url" {
  description = "PMTiles archive cut by the extract Job: a Protomaps daily build (https://build.protomaps.com/YYYYMMDD.pmtiles, removed after some days) or an internal http(s):// or s3:// mirror (air-gapped). No default: daily builds expire, so set a current build or a mirror. Required, unless geo_protomaps_existing_claim is set, when geo_basemap_provider is \"protomaps\". Empty: no Job; geo_protomaps_existing_claim must hold basemap.pmtiles."
  type        = string
  default     = ""
}

variable "geo_protomaps_bbox" {
  description = "Area of the extract, \"min_lon,min_lat,max_lon,max_lat\". Default: the contiguous United States. Empty: the whole source."
  type        = string
  default     = "-125.0,24.0,-66.5,49.5"
}

variable "geo_protomaps_max_zoom" {
  description = "Highest zoom level of the extract (0-15)."
  type        = number
  default     = 10
}

variable "geo_protomaps_storage_size" {
  description = "Size of the basemap PVC; it must hold the extract."
  type        = string
  default     = "10Gi"
}

variable "geo_protomaps_existing_claim" {
  description = "Existing PVC in the GoodData.CN namespace with basemap.pmtiles (customer-provided file). Set it to skip the PVC and the extract Job."
  type        = string
  default     = ""
}

variable "geo_mapbox_token" {
  description = "Mapbox access token. Required when geo_basemap_provider is \"mapbox\"."
  type        = string
  sensitive   = true
  default     = ""

  validation {
    condition     = var.geo_basemap_provider != "mapbox" || trimspace(var.geo_mapbox_token) != ""
    error_message = "geo_mapbox_token must be set when geo_basemap_provider is \"mapbox\"."
  }
}

variable "helm_aws_lb_controller_version" {
  description = "Version of the aws-load-balancer-controller Helm chart to deploy. https://artifacthub.io/packages/helm/aws/aws-load-balancer-controller"
  type        = string
  # renovate: depName=aws-load-balancer-controller registryUrl=https://aws.github.io/eks-charts
  default = "3.6.2"
}

variable "helm_cert_manager_version" {
  description = "Version of the cert-manager Helm chart to deploy. https://artifacthub.io/packages/helm/cert-manager/cert-manager"
  type        = string
  # renovate: depName=cert-manager registryUrl=https://charts.jetstack.io
  default = "v1.21.3"
}

variable "helm_clickhouse_operator_version" {
  description = "Version of the clickhouse-operator-helm Helm chart to deploy. https://github.com/ClickHouse/clickhouse-operator"
  type        = string
  # renovate: depName=clickhouse-operator-helm packageName=ghcr.io/clickhouse/clickhouse-operator-helm datasource=docker
  default = "0.0.7"
}

variable "helm_external_dns_version" {
  description = "Version of the external-dns Helm chart to deploy. https://artifacthub.io/packages/helm/external-dns/external-dns"
  type        = string
  # renovate: depName=external-dns registryUrl=https://kubernetes-sigs.github.io/external-dns/
  default = "1.23.0"
}

variable "helm_gdcn_version" {
  description = "Version of the gooddata-cn Helm chart to deploy. https://artifacthub.io/packages/helm/gooddata-cn/gooddata-cn"
  type        = string
  validation {
    # A version carrying semver build metadata (1.2.3+abc) is a pre-release chart
    # that the release-number floors below cannot be checked against.
    condition = strcontains(var.helm_gdcn_version, "+") ? true : (
      # ALB support requires GoodData chart features introduced in 3.51+
      (var.ingress_controller != "alb" ? true : (
        length(split(".", var.helm_gdcn_version)) >= 2 &&
        can(tonumber(split(".", var.helm_gdcn_version)[0])) &&
        can(tonumber(split(".", var.helm_gdcn_version)[1])) &&
        (
          tonumber(split(".", var.helm_gdcn_version)[0]) > 3 ||
          (
            tonumber(split(".", var.helm_gdcn_version)[0]) == 3 &&
            tonumber(split(".", var.helm_gdcn_version)[1]) >= 51
          )
        )
      )) &&
      # Istio existingGateway support (incl Dex) requires GoodData chart features introduced in 3.53+
      (var.ingress_controller != "istio_gateway" ? true : (
        length(split(".", var.helm_gdcn_version)) >= 2 &&
        can(tonumber(split(".", var.helm_gdcn_version)[0])) &&
        can(tonumber(split(".", var.helm_gdcn_version)[1])) &&
        (
          tonumber(split(".", var.helm_gdcn_version)[0]) > 3 ||
          (
            tonumber(split(".", var.helm_gdcn_version)[0]) == 3 &&
            tonumber(split(".", var.helm_gdcn_version)[1]) >= 53
          )
        )
      ))
    )
    error_message = "Invalid helm_gdcn_version for selected features. ingress_controller=\"alb\" requires helm_gdcn_version >= 3.51.0. ingress_controller=\"istio_gateway\" requires helm_gdcn_version >= 3.53.0."
  }
}

variable "helm_grafana_version" {
  description = "Version of the grafana Helm chart to deploy. https://artifacthub.io/packages/helm/grafana/grafana"
  type        = string
  # renovate: depName=grafana registryUrl=https://grafana.github.io/helm-charts
  default = "10.5.15"
}

variable "helm_istio_version" {
  description = "Version of the Istio Helm charts (base, istiod, gateway). https://istio.io/latest/docs/setup/install/helm/"
  type        = string
  # renovate: depName=base registryUrl=https://istio-release.storage.googleapis.com/charts
  default = "1.30.8"
}

variable "helm_karpenter_version" {
  description = "Version of the Karpenter Helm chart (oci://public.ecr.aws/karpenter/karpenter) to deploy. https://github.com/aws/karpenter-provider-aws/releases"
  type        = string
  # renovate: depName=karpenter packageName=public.ecr.aws/karpenter/karpenter datasource=docker
  default = "1.6.3"
}

variable "helm_langfuse_version" {
  description = "Version of the langfuse Helm chart to deploy. https://artifacthub.io/packages/helm/langfuse/langfuse"
  type        = string
  # renovate: depName=langfuse registryUrl=https://langfuse.github.io/langfuse-k8s
  default = "2.2.4"
}

variable "helm_loki_version" {
  description = "Version of the loki Helm chart to deploy. https://artifacthub.io/packages/helm/grafana/loki"
  type        = string
  # renovate: depName=loki registryUrl=https://grafana.github.io/helm-charts
  default = "7.3.0"
}

variable "helm_metrics_server_version" {
  description = "Version of the metrics-server Helm chart to deploy. https://artifacthub.io/packages/helm/metrics-server/metrics-server"
  type        = string
  # renovate: depName=metrics-server registryUrl=https://kubernetes-sigs.github.io/metrics-server/
  default = "3.14.0"
}

variable "helm_kube_prometheus_stack_version" {
  description = "Version of the kube-prometheus-stack Helm chart to deploy. https://artifacthub.io/packages/helm/prometheus-community/kube-prometheus-stack"
  type        = string
  # renovate: depName=kube-prometheus-stack registryUrl=https://prometheus-community.github.io/helm-charts
  default = "93.1.1"
}

variable "helm_promtail_version" {
  description = "Version of the promtail Helm chart to deploy. https://artifacthub.io/packages/helm/grafana/promtail"
  type        = string
  # renovate: depName=promtail registryUrl=https://grafana.github.io/helm-charts
  default = "6.17.1"
}

variable "helm_pulsar_version" {
  description = "Version of the pulsar Helm chart to deploy. https://artifacthub.io/packages/helm/apache/pulsar"
  type        = string
  # renovate: depName=pulsar registryUrl=https://pulsar.apache.org/charts
  default = "4.8.0"
}

variable "helm_starrocks_version" {
  description = "Version of the kube-starrocks Helm chart to deploy. https://artifacthub.io/packages/helm/kube-starrocks/kube-starrocks"
  type        = string
  # renovate: depName=kube-starrocks registryUrl=https://starrocks.github.io/starrocks-kubernetes-operator
  default = "1.11.8"
}

variable "helm_tempo_version" {
  description = "Version of the tempo Helm chart to deploy. https://artifacthub.io/packages/helm/grafana/tempo"
  type        = string
  # renovate: depName=tempo registryUrl=https://grafana.github.io/helm-charts
  default = "1.24.4"
}

variable "helm_traefik_version" {
  description = "Version of the Traefik Helm chart to deploy. https://artifacthub.io/packages/helm/traefik/traefik"
  type        = string
  # renovate: depName=traefik registryUrl=https://traefik.github.io/charts
  default = "42.3.1"
}

variable "ingress_behind_l7" {
  description = "Whether the ingress controller is running behind an L7 proxy/load balancer (enables trusting X-Forwarded-* headers)."
  type        = bool
  default     = false
}

variable "ingress_controller" {
  description = "Ingress controller used to expose GoodData.CN. Use alb for AWS ALB, traefik for Kubernetes Ingress via Traefik, or istio_gateway to expose the Istio ingress gateway via LoadBalancer."
  type        = string
  default     = "alb"
  validation {
    condition = (
      contains(["traefik", "alb", "istio_gateway"], var.ingress_controller)
    )
    error_message = "ingress_controller must be one of: \"alb\", \"traefik\", \"istio_gateway\". ingress-nginx was removed: use \"traefik\", and rename ingress_nginx_behind_l7 -> ingress_behind_l7 and helm_ingress_nginx_version -> helm_traefik_version."
  }
}

# GoodData internal use only: install an unreleased build instead of the public
# chart. See "Installing an internal build" in the README.
variable "internal_chart_repository" {
  description = "Chart repository for gooddata-cn. Leave at the default unless installing an internal build."
  type        = string
  default     = "https://charts.gooddata.com/"
}

variable "internal_registry_aws_profile" {
  description = "AWS CLI profile used to mint an ECR token when internal_registry_server is an ECR host. Falls back to aws_profile_name."
  type        = string
  default     = ""
}

variable "internal_registry_password" {
  description = "Password for internal_registry_server. Required for a non-ECR host; an ECR host mints its own token."
  type        = string
  sensitive   = true
  default     = ""
}

variable "internal_registry_server" {
  description = "Registry holding an internal build's chart and images. Also authenticates internal_chart_repository when the chart lives on the same host. Empty uses the public chart and images."
  type        = string
  default     = ""
}

variable "internal_registry_username" {
  description = "Username for internal_registry_server. Required for a non-ECR host; an ECR host mints its own token."
  type        = string
  default     = ""
}

variable "langfuse_admin_email" {
  description = "Email of the bootstrap Langfuse admin."
  type        = string
  default     = ""

  validation {
    condition     = var.enable_llm_observability ? length(trimspace(var.langfuse_admin_email)) > 0 : true
    error_message = "langfuse_admin_email must be provided when enable_llm_observability is true."
  }
}

variable "langfuse_tracing_environment" {
  description = "Langfuse tracing environment reported by the GoodData.CN gen-ai services. Empty keeps the chart default."
  type        = string
  default     = "dev"
}

variable "letsencrypt_email" {
  description = "Email address used for Let's Encrypt ACME registration (only required when tls_mode = \"letsencrypt\")"
  type        = string
  default     = ""
  validation {
    condition     = var.tls_mode != "letsencrypt" ? true : length(trimspace(var.letsencrypt_email)) > 0
    error_message = "letsencrypt_email must be provided when tls_mode is \"letsencrypt\"."
  }
}

variable "llm_observability_hostname" {
  description = "Hostname for the Langfuse UI"
  type        = string
  default     = ""

  validation {
    condition     = var.enable_llm_observability ? length(trimspace(var.llm_observability_hostname)) > 0 : true
    error_message = "llm_observability_hostname must be provided when enable_llm_observability is true."
  }
}

variable "loki_retention_period" {
  description = "Loki log retention period (Go duration; multiple of 24h, e.g. 168h = 7 days)."
  type        = string
  default     = "168h"
}

variable "prometheus_retention_period" {
  description = "Prometheus metrics retention period (e.g. 168h = 7 days)."
  type        = string
  default     = "168h"
}

variable "tempo_retention_period" {
  description = "Tempo trace retention period (Go duration, e.g. 168h = 7 days)."
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

variable "rds_allocated_storage" {
  description = "RDS PostgreSQL allocated storage in GB. If null, chosen by size_profile."
  type        = number
  default     = null
}

variable "rds_allow_major_version_upgrade" {
  description = "Allow RDS engine major version upgrades when engine_version changes across major versions."
  type        = bool
  default     = false
}

variable "rds_apply_immediately" {
  description = "Apply RDS modifications during terraform apply instead of the next maintenance window. Instance-class changes reboot the database, so leave this off unless you accept downtime."
  type        = bool
  default     = false
}

variable "rds_backup_retention_period" {
  description = "Days of automated RDS backups / point-in-time recovery. If null, chosen by size_profile (14 for prod, 7 for dev)."
  type        = number
  default     = null
  validation {
    # coalesce keeps floor() off a null value: Terraform before 1.12
    # evaluates both sides of ||.
    condition = (
      coalesce(var.rds_backup_retention_period, 0) == floor(coalesce(var.rds_backup_retention_period, 0))
      && coalesce(var.rds_backup_retention_period, 0) >= 0
      && coalesce(var.rds_backup_retention_period, 0) <= 35
    )
    error_message = "rds_backup_retention_period must be a whole number of days between 0 and 35."
  }
}

variable "rds_deletion_protection" {
  description = "Enable deletion protection on the RDS instance. If null, chosen by size_profile (on for prod, off for dev)."
  type        = bool
  default     = null
}

variable "rds_instance_class" {
  description = "RDS PostgreSQL instance class. If null, chosen by size_profile."
  type        = string
  default     = null
}

variable "rds_skip_final_snapshot" {
  description = "Skip taking a final snapshot when destroying the RDS instance. If null, chosen by size_profile (final snapshot for prod, skipped for dev)."
  type        = bool
  default     = null
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID used for DNS and ACM validation when dns_provider = \"route53\"."
  type        = string
  default     = ""
  validation {
    condition     = var.dns_provider != "route53" ? true : length(trimspace(var.route53_zone_id)) > 0
    error_message = "route53_zone_id is required when dns_provider is \"route53\"."
  }
}

variable "size_profile" {
  description = "Sizing profile for GoodData.CN and supporting services."
  type        = string
  default     = "prod-small"
  validation {
    condition     = contains(["dev", "prod-small", "prod-xl", "prod-large"], var.size_profile)
    error_message = "size_profile must be one of: dev, prod-small, prod-xl, prod-large."
  }
}

variable "starrocks_cn_image_tag" {
  description = "Docker image tag for StarRocks CN nodes"
  type        = string
  default     = "4.0.6-20260507-091022-3c12ee9"
}

variable "starrocks_fe_image_tag" {
  description = "Docker image tag for StarRocks FE nodes"
  type        = string
  default     = "4.0.6-20260507-091022-3c12ee9"
}

variable "tls_mode" {
  description = "TLS management mode. Use acm for ALB, letsencrypt for Traefik or Istio."
  type        = string
  default     = "acm"
  validation {
    condition = (
      contains(["acm", "letsencrypt"], var.tls_mode) &&
      (var.tls_mode != "acm" ? true : var.ingress_controller == "alb") &&
      (var.tls_mode != "letsencrypt" ? true : contains(["traefik", "istio_gateway"], var.ingress_controller))
    )
    error_message = "tls_mode=\"acm\" requires ingress_controller=\"alb\"; tls_mode=\"letsencrypt\" requires ingress_controller=\"traefik\" or \"istio_gateway\"."
  }
}
