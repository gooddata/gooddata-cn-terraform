variable "auth_hostname" {
  description = "Hostname for the default GoodData identity provider (Dex) ingress."
  type        = string
  validation {
    condition     = length(trimspace(var.auth_hostname)) > 0
    error_message = "auth_hostname must be provided."
  }
}

variable "deployment_name" {
  description = "Name prefix for all STACKIT resources."
  type        = string
  default     = "gooddata-cn"

  validation {
    condition     = can(regex("^[a-z0-9-]{1,50}$", var.deployment_name)) && length(join("", regexall("[0-9a-z]", lower(var.deployment_name)))) <= 18
    error_message = "The deployment_name must contain only lowercase letters, numbers, and hyphens. After removing non-alphanumeric characters, it must be ≤18 characters to allow space for 6-character random suffix."
  }
}

variable "dns_provider" {
  description = "DNS management mode on STACKIT. \"self-managed\" leaves DNS to the user; \"stackit-dns\" enables the SKE DNS extension (managed externalDNS) against a STACKIT DNS zone and maintains records for each GoodData hostname."
  type        = string
  default     = "self-managed"
  validation {
    condition     = contains(["self-managed", "stackit-dns"], var.dns_provider)
    error_message = "dns_provider must be \"self-managed\" or \"stackit-dns\"."
  }
}

variable "enable_ai_features" {
  description = "Enable AI features in the gooddata-cn chart (GenAI service, semantic search, chat, metadata sync, and Qdrant)."
  type        = bool
  default     = true
}

variable "enable_experimental_features" {
  description = "Enable experimental AI features in the gooddata-cn chart. These are subject to change and the set of features may evolve over time."
  type        = bool
  default     = false
}

variable "enable_image_cache" {
  description = "Image caching is unavailable on STACKIT: its Container Registry has no Terraform resources, so no pull-through cache can be provisioned. Point registry_dockerio at a mirror instead."
  type        = bool
  default     = false
  validation {
    condition     = var.enable_image_cache == false
    error_message = "enable_image_cache is not supported on STACKIT. Set registry_dockerio/registry_quayio/registry_k8sio to a mirror instead."
  }
}

variable "enable_observability" {
  description = "Enable observability stack (Prometheus, Loki, Tempo, Grafana)"
  type        = bool
  default     = false
}

variable "gdcn_helm_extra_values" {
  description = "Additional Helm values YAML string appended to the gooddata-cn chart values. Use to override sub-chart settings not exposed as Terraform variables."
  type        = string
  default     = ""
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

variable "helm_cert_manager_version" {
  description = "Version of the cert-manager Helm chart to deploy. https://artifacthub.io/packages/helm/cert-manager/cert-manager"
  type        = string
  # renovate: depName=cert-manager registryUrl=https://charts.jetstack.io
  default = "v1.21.0"
}

variable "helm_gdcn_version" {
  description = "Version of the gooddata-cn Helm chart to deploy. https://artifacthub.io/packages/helm/gooddata-cn/gooddata-cn"
  type        = string

  validation {
    condition = (
      var.ingress_controller != "istio_gateway" ? true : (
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
      )
    )
    error_message = "ingress_controller=\"istio_gateway\" requires helm_gdcn_version >= 3.53.0."
  }
}

variable "helm_grafana_version" {
  description = "Version of the grafana Helm chart to deploy. https://artifacthub.io/packages/helm/grafana/grafana"
  type        = string
  # renovate: depName=grafana registryUrl=https://grafana.github.io/helm-charts
  default = "10.5.15"
}

variable "helm_ingress_nginx_version" {
  description = "Version of the ingress-nginx Helm chart to deploy. https://artifacthub.io/packages/helm/ingress-nginx/ingress-nginx"
  type        = string
  # renovate: depName=ingress-nginx registryUrl=https://kubernetes.github.io/ingress-nginx
  default = "4.15.1"
}

variable "helm_istio_version" {
  description = "Version of the Istio Helm charts (base, istiod, gateway). https://istio.io/latest/docs/setup/install/helm/"
  type        = string
  # renovate: depName=base registryUrl=https://istio-release.storage.googleapis.com/charts
  default = "1.30.3"
}

variable "helm_loki_version" {
  description = "Version of the loki Helm chart to deploy. https://artifacthub.io/packages/helm/grafana/loki"
  type        = string
  # renovate: depName=loki registryUrl=https://grafana.github.io/helm-charts
  default = "7.1.0"
}

variable "helm_kube_prometheus_stack_version" {
  description = "Version of the kube-prometheus-stack Helm chart to deploy. https://artifacthub.io/packages/helm/prometheus-community/kube-prometheus-stack"
  type        = string
  # renovate: depName=kube-prometheus-stack registryUrl=https://prometheus-community.github.io/helm-charts
  default = "87.19.2"
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
  default = "4.7.0"
}

variable "helm_tempo_version" {
  description = "Version of the tempo Helm chart to deploy. https://artifacthub.io/packages/helm/grafana/tempo"
  type        = string
  # renovate: depName=tempo registryUrl=https://grafana.github.io/helm-charts
  default = "1.24.4"
}

variable "ingress_controller" {
  description = "Ingress controller to deploy. Use ingress-nginx for Kubernetes Ingress, or istio_gateway to expose the Istio ingress gateway via LoadBalancer. Either way SKE's built-in yawol controller provisions the load balancer."
  type        = string
  default     = "ingress-nginx"

  validation {
    condition     = contains(["ingress-nginx", "istio_gateway"], var.ingress_controller)
    error_message = "ingress_controller must be one of: \"ingress-nginx\", \"istio_gateway\"."
  }
}

variable "ingress_nginx_behind_l7" {
  description = "Whether ingress-nginx is running behind an L7 proxy/load balancer (enables use-forwarded-headers). yawol is an L4 load balancer, so this stays false unless you front it with something else."
  type        = bool
  default     = false
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

variable "postgresflex_backup_retention_days" {
  description = "Days of automated PostgreSQL Flex backups. If null, chosen by size_profile (90 for prod, 32 for dev). STACKIT only accepts 32-90."
  type        = number
  default     = null
  validation {
    condition     = var.postgresflex_backup_retention_days == null || (var.postgresflex_backup_retention_days >= 32 && var.postgresflex_backup_retention_days <= 90)
    error_message = "postgresflex_backup_retention_days must be between 32 and 90 days."
  }
}

variable "postgresflex_flavor_id" {
  description = "PostgreSQL Flex flavor ID as vCPU.RAM, with a -replica suffix for 3-node replication and no suffix for single-node: e.g. \"4.8\" or \"4.8-replica\". Only 2.4, 2.16, 4.8, 4.32, 8.16, 16.32 and 16.128 exist. If null, chosen by size_profile. List what your project offers with: stackit postgresflex flavor list"
  type        = string
  default     = null
}

variable "postgresflex_storage_class" {
  description = "Storage class for the PostgreSQL Flex instance's data volume. If null, chosen by size_profile. List options with: stackit postgresflex options --storages --flavor-id FLAVOR_ID"
  type        = string
  default     = null
}

variable "registry_dockerio" {
  description = "Container registry hostname used for images normally pulled from docker.io. Point this at a mirror to avoid Docker Hub anonymous pull limits."
  type        = string
  default     = "docker.io"
}

variable "registry_k8sio" {
  description = "Container registry hostname used for images normally pulled from registry.k8s.io."
  type        = string
  default     = "registry.k8s.io"
}

variable "registry_quayio" {
  description = "Container registry hostname used for images normally pulled from quay.io."
  type        = string
  default     = "quay.io"
}

variable "size_profile" {
  description = "Sizing profile for GoodData.CN and supporting services."
  type        = string
  default     = "prod-small"
  validation {
    condition     = contains(["dev", "prod-small", "prod-large"], var.size_profile)
    error_message = "size_profile must be one of: dev, prod-small, prod-large."
  }
}

variable "ske_api_server_authorized_ip_ranges" {
  description = "List of CIDR ranges allowed to reach the SKE API server, applied as the cluster ACL extension. Leave empty to allow any source."
  type        = list(string)
  default     = []
}

variable "ske_system_machine_type" {
  description = "Machine type for the system node pool, which is reserved for cluster-critical pods. If null, chosen by size_profile."
  type        = string
  default     = null
}

variable "ske_system_min_nodes" {
  description = "Minimum nodes in the system pool. If null, chosen by size_profile."
  type        = number
  default     = null
}

variable "ske_version" {
  description = "Minimum Kubernetes version for the SKE cluster. If null, SKE uses the latest supported version. SKE treats this as a floor and may upgrade past it."
  type        = string
  default     = null
}

variable "ske_workload_machine_type" {
  description = "Machine type for the workload node pool. If null, chosen by size_profile. The g-series is 1:4 vCPU:RAM; the trailing \"d\" means no CPU overcommit."
  type        = string
  default     = null
}

variable "ske_workload_max_nodes" {
  description = "Maximum nodes in the workload pool. This is the ceiling SKE's cluster autoscaler scales up to, and the main cost bound. If null, chosen by size_profile."
  type        = number
  default     = null
}

variable "ske_workload_min_nodes" {
  description = "Minimum nodes in the workload pool. If null, chosen by size_profile."
  type        = number
  default     = null
}

variable "stackit_additional_labels" {
  description = "Map of additional labels merged into the common labels. Only STACKIT network resources accept labels; SKE, PostgreSQL Flex, object storage and DNS have no label field."
  type        = map(string)
  default     = {}
}

variable "stackit_availability_zones" {
  description = "Availability zones for the SKE node pools, e.g. [\"eu01-1\", \"eu01-2\", \"eu01-3\"]. Must belong to stackit_region."
  type        = list(string)
  default     = ["eu01-1", "eu01-2", "eu01-3"]
  validation {
    condition     = length(var.stackit_availability_zones) > 0
    error_message = "stackit_availability_zones must list at least one zone."
  }
  validation {
    condition     = alltrue([for z in var.stackit_availability_zones : startswith(z, "${var.stackit_region}-")])
    error_message = "Every entry in stackit_availability_zones must start with \"<stackit_region>-\", e.g. \"eu01-1\" for region \"eu01\"."
  }
}

variable "stackit_dns_zone_name" {
  description = "DNS zone name (e.g. \"example.com\") managed via STACKIT DNS when dns_provider = \"stackit-dns\". The zone is created by Terraform; delegate it at your registrar using the stackit_dns_primary_name_server output and the full name server set shown for the zone in the STACKIT Portal."
  type        = string
  default     = ""
  validation {
    condition     = var.dns_provider != "stackit-dns" || length(trimspace(var.stackit_dns_zone_name)) > 0
    error_message = "stackit_dns_zone_name is required when dns_provider is \"stackit-dns\"."
  }
}

variable "stackit_private_networking" {
  description = "Place the SKE control plane and PostgreSQL Flex inside a STACKIT Network Area (SNA) instead of exposing them publicly. Requires stackit_project_id to already belong to a network area, which is an organization-level prerequisite configured outside this repo. Postgres SNA support is also account-gated; set false to fall back to public endpoints restricted by CIDR ACL. The cluster's control-plane access scope is immutable, so changing this recreates the cluster."
  type        = bool
  default     = true
}

variable "stackit_project_id" {
  description = "STACKIT project ID (UUID) that owns all resources."
  type        = string
  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.stackit_project_id))
    error_message = "stackit_project_id must be a UUID."
  }
}

variable "stackit_region" {
  description = "STACKIT region to deploy resources to (eu01 = Germany, eu02 = Austria)."
  type        = string
  default     = "eu01"
}

variable "stackit_storage_class" {
  description = "Kubernetes StorageClass for GoodData.CN chart PVCs. If null, chosen by size_profile. SKE ships premium-perf0/1/2/4/6-stackit; Terraform does not create these."
  type        = string
  default     = null
}

variable "tls_mode" {
  description = "TLS management mode. Use letsencrypt for Let's Encrypt certificates."
  type        = string
  default     = "letsencrypt"
  validation {
    condition     = var.tls_mode == "letsencrypt"
    error_message = "tls_mode must be \"letsencrypt\" on STACKIT."
  }
}
