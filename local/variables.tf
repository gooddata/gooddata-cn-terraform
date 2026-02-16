variable "auth_hostname" {
  description = "Hostname for the default GoodData identity provider (Dex) ingress."
  type        = string
  default     = "localhost"
  validation {
    condition     = length(trimspace(var.auth_hostname)) > 0
    error_message = "auth_hostname must be provided."
  }
}

variable "deployment_name" {
  description = "Name prefix for local resources (and Helm releases)."
  type        = string
  default     = "gooddata-cn-local"
  validation {
    condition     = can(regex("^[a-z](?:[a-z0-9-]*[a-z0-9])?$", var.deployment_name))
    error_message = "deployment_name must be lowercase, start with a letter, contain only letters, numbers, and hyphens, and must not end with a hyphen."
  }
}

variable "dockerhub_access_token" {
  description = "Optional Docker Hub password/PAT used by k3d registry auth config."
  type        = string
  default     = ""
  sensitive   = true
}

variable "dockerhub_username" {
  description = "Optional Docker Hub username used by k3d registry auth config."
  type        = string
  default     = ""
  sensitive   = true
}

variable "enable_ai_features" {
  description = "Enable AI features in the gooddata-cn chart (GenAI service, semantic search, chat, metadata sync, and Qdrant)."
  type        = bool
  default     = true
}

variable "enable_observability" {
  description = "Enable observability stack (Prometheus, Loki, Tempo, Grafana)"
  type        = bool
  default     = false
}

variable "gdcn_license_key" {
  description = "GoodData.CN license key (provided by your GoodData contact)."
  type        = string
  sensitive   = true
  validation {
    condition     = length(trimspace(var.gdcn_license_key)) > 0
    error_message = "gdcn_license_key must be provided."
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
  description = "Version of the cert-manager Helm chart to deploy."
  type        = string
  default     = "v1.18.2"
}

variable "helm_cnpg_version" {
  description = "Version of the CloudNativePG Helm chart to deploy."
  type        = string
  default     = "0.27.0"
}

variable "helm_gdcn_version" {
  description = "Version of the gooddata-cn Helm chart to deploy."
  type        = string
  default     = "3.36.0"

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
  description = "Version of the grafana Helm chart to deploy."
  type        = string
  default     = "8.10.0"
}

variable "helm_ingress_nginx_version" {
  description = "Version of the ingress-nginx Helm chart to deploy."
  type        = string
  default     = "4.12.3"
}

variable "helm_istio_version" {
  description = "Version of the Istio Helm charts (base, istiod, gateway)."
  type        = string
  default     = "1.28.2"
}

variable "helm_loki_version" {
  description = "Version of the loki Helm chart to deploy."
  type        = string
  default     = "6.30.1"
}

variable "helm_prometheus_version" {
  description = "Version of the prometheus Helm chart to deploy."
  type        = string
  default     = "27.39.0"
}

variable "helm_promtail_version" {
  description = "Version of the promtail Helm chart to deploy."
  type        = string
  default     = "6.17.0"
}

variable "helm_pulsar_version" {
  description = "Version of the pulsar Helm chart to deploy."
  type        = string
  default     = "3.9.0"
}

variable "helm_tempo_version" {
  description = "Version of the tempo Helm chart to deploy."
  type        = string
  default     = "1.23.2"
}

variable "ingress_controller" {
  description = "Ingress controller used to expose GoodData.CN."
  type        = string
  default     = "ingress-nginx"
  validation {
    condition     = contains(["ingress-nginx", "istio_gateway"], var.ingress_controller)
    error_message = "For local deployments, ingress_controller must be one of: \"ingress-nginx\", \"istio_gateway\"."
  }
}

variable "ingress_nginx_behind_l7" {
  description = "Whether ingress-nginx is running behind an L7 proxy/load balancer (enables use-forwarded-headers)."
  type        = bool
  default     = false
}

variable "k3d_cluster_name" {
  description = "k3d cluster name to create/manage."
  type        = string
  default     = "gdcluster"
  validation {
    condition     = length(trimspace(var.k3d_cluster_name)) > 0
    error_message = "k3d_cluster_name must be provided."
  }
}

variable "k3d_kubeapi_host" {
  description = "Hostname to use in the generated kubeconfig for the k3d Kubernetes API server. Use host.docker.internal when running Terraform inside a container; use 127.0.0.1 on Linux hosts without host.docker.internal."
  type        = string
  default     = "host.docker.internal"
  validation {
    condition     = length(trimspace(var.k3d_kubeapi_host)) > 0
    error_message = "k3d_kubeapi_host must be provided."
  }
}

variable "kubeconfig_context" {
  description = "Kubeconfig context to use. If empty, defaults to k3d-<k3d_cluster_name>."
  type        = string
  default     = ""
}

variable "kubeconfig_path" {
  description = "Path to kubeconfig file to use (k3d updates this by default)."
  type        = string
  default     = "~/.kube/config"
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

variable "registry_dockerio" {
  description = "Container registry hostname used for images normally pulled from docker.io."
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
  default     = "dev"
  validation {
    condition     = contains(["dev"], var.size_profile)
    error_message = "size_profile must be \"dev\" for local installs."
  }
}

variable "tls_mode" {
  description = "TLS management mode for local installs. Use selfsigned for cert-manager self-signed certificates."
  type        = string
  default     = "selfsigned"
  validation {
    condition     = contains(["selfsigned"], var.tls_mode)
    error_message = "tls_mode must be \"selfsigned\" for local installs."
  }
}
