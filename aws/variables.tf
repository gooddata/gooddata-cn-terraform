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

variable "eks_max_nodes" {
  description = "Maximum number of EKS worker nodes"
  type        = number
  default     = 10
}

variable "eks_node_types" {
  description = "List of EC2 instance types for EKS worker nodes"
  type        = list(string)
  default     = ["m6i.xlarge"]
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

variable "enable_image_cache" {
  description = "Enable image caching (ECR pull-through cache). If false, images are pulled from upstream registries directly."
  type        = bool
  default     = false
}

variable "gdcn_license_key" {
  description = "GoodData.CN license key (provided by your GoodData contact)"
  type        = string
  sensitive   = true
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

variable "helm_aws_lb_controller_version" {
  description = "Version of the aws-load-balancer-controller Helm chart to deploy. https://artifacthub.io/packages/helm/aws/aws-load-balancer-controller"
  type        = string
  default     = "1.13.3"
}

variable "helm_cert_manager_version" {
  description = "Version of the cert-manager Helm chart to deploy. https://artifacthub.io/packages/helm/cert-manager/cert-manager"
  type        = string
  default     = "v1.18.2"
}

variable "helm_cluster_autoscaler_version" {
  description = "Version of the cluster-autoscaler Helm chart to deploy. https://artifacthub.io/packages/helm/cluster-autoscaler/cluster-autoscaler"
  type        = string
  default     = "9.46.6"
}

variable "helm_external_dns_version" {
  description = "Version of the external-dns Helm chart to deploy. https://artifacthub.io/packages/helm/external-dns/external-dns"
  type        = string
  default     = "1.20.0"
}

variable "helm_gdcn_version" {
  description = "Version of the gooddata-cn Helm chart to deploy. https://artifacthub.io/packages/helm/gooddata-cn/gooddata-cn"
  type        = string
  validation {
    condition = (
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

variable "helm_ingress_nginx_version" {
  description = "Version of the ingress-nginx Helm chart to deploy. https://artifacthub.io/packages/helm/ingress-nginx/ingress-nginx"
  type        = string
  default     = "4.12.3"
}

variable "helm_istio_version" {
  description = "Version of the Istio Helm charts (base, istiod, gateway). https://istio.io/latest/docs/setup/install/helm/"
  type        = string
  default     = "1.28.2"
}

variable "helm_metrics_server_version" {
  description = "Version of the metrics-server Helm chart to deploy. https://artifacthub.io/packages/helm/metrics-server/metrics-server"
  type        = string
  default     = "3.13.0"
}

variable "helm_pulsar_version" {
  description = "Version of the pulsar Helm chart to deploy. https://artifacthub.io/packages/helm/apache/pulsar"
  type        = string
  default     = "3.9.0"
}

variable "ingress_controller" {
  description = "Ingress controller used to expose GoodData.CN. Use alb for AWS ALB, ingress-nginx for Kubernetes Ingress, or istio_gateway to expose the Istio ingress gateway via LoadBalancer."
  type        = string
  default     = "alb"
  validation {
    condition = (
      contains(["ingress-nginx", "alb", "istio_gateway"], var.ingress_controller)
    )
    error_message = "ingress_controller must be one of: \"alb\", \"ingress-nginx\", \"istio_gateway\"."
  }
}

variable "ingress_nginx_behind_l7" {
  description = "Whether ingress-nginx is running behind an L7 proxy/load balancer (enables use-forwarded-headers)."
  type        = bool
  default     = false
}

variable "letsencrypt_email" {
  description = "Email address used for Let's Encrypt ACME registration (only required when tls_mode = \"cert-manager\")"
  type        = string
  default     = ""
  validation {
    condition     = var.tls_mode != "cert-manager" ? true : length(trimspace(var.letsencrypt_email)) > 0
    error_message = "letsencrypt_email must be provided when tls_mode is \"cert-manager\"."
  }
}

variable "rds_deletion_protection" {
  description = "Enable deletion protection on the RDS instance."
  type        = bool
  default     = false
}

variable "rds_instance_class" {
  description = "RDS PostgreSQL instance class"
  type        = string
  default     = "db.t4g.medium"
}

variable "rds_skip_final_snapshot" {
  description = "Skip taking a final snapshot when destroying the RDS instance."
  type        = bool
  default     = true
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
    condition     = contains(["dev", "prod-small"], var.size_profile)
    error_message = "size_profile must be one of: dev, prod-small."
  }
}

variable "tls_mode" {
  description = "TLS management mode. Use acm for ALB, cert-manager for ingress-nginx."
  type        = string
  default     = "acm"
  validation {
    condition = (
      contains(["acm", "cert-manager"], var.tls_mode) &&
      (var.tls_mode != "acm" ? true : var.ingress_controller == "alb") &&
      (var.tls_mode != "cert-manager" ? true : contains(["ingress-nginx", "istio_gateway"], var.ingress_controller))
    )
    error_message = "tls_mode=\"acm\" requires ingress_controller=\"alb\"; tls_mode=\"cert-manager\" requires ingress_controller=\"ingress-nginx\" or \"istio_gateway\"."
  }
}
