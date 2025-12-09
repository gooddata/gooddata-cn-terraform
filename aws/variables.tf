variable "alb_controller_replica_count" {
  description = "Replica count for the AWS Load Balancer Controller."
  type        = number
  default     = 1
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

variable "base_domain" {
  description = "Base domain used to construct GoodData hostnames. When empty, Terraform derives one from the ingress configuration."
  type        = string
  default     = ""
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

variable "enable_image_cache" {
  description = "Enable image caching (ECR pull-through cache). If false, images are pulled from upstream registries directly."
  type        = bool
  default     = false
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
  default     = null
}

variable "gdcn_license_key" {
  description = "GoodData.CN license key (provided by your GoodData contact)"
  type        = string
  sensitive   = true
}

variable "gdcn_org_ids" {
  description = "List of organization IDs/DNS labels that GoodData.CN should trust (also controls Dex allowedOrigins)."
  type        = list(string)
  default     = ["org"]
  validation {
    condition = length(var.gdcn_org_ids) > 0 && alltrue([
      for id in var.gdcn_org_ids : can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", id))
    ])
    error_message = "gdcn_org_ids must contain at least one lowercase alphanumeric DNS label (hyphens allowed, but not at the beginning or end)."
  }
}

variable "gdcn_replica_count" {
  description = "Replica count for GoodData.CN components (passed to the chart). Default is 2 for high availability."
  type        = number
  default     = 1
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
  default     = "1.15.1"
}

variable "helm_gdcn_version" {
  description = "Version of the gooddata-cn Helm chart to deploy. https://artifacthub.io/packages/helm/gooddata-cn/gooddata-cn"
  type        = string
  validation {
    condition = var.ingress_controller != "alb" ? true : (
      length(split(".", var.helm_gdcn_version)) >= 2 &&
      can(tonumber(split(".", var.helm_gdcn_version)[0])) &&
      can(tonumber(split(".", var.helm_gdcn_version)[1])) &&
      (
        tonumber(split(".", var.helm_gdcn_version)[0]) > 3 ||
        (
          tonumber(split(".", var.helm_gdcn_version)[0]) == 3 &&
          tonumber(split(".", var.helm_gdcn_version)[1]) >= 50
        )
      )
    )
    error_message = "ingress_controller = \"alb\" requires helm_gdcn_version >= 3.50.0."
  }
}

variable "helm_ingress_nginx_version" {
  description = "Version of the ingress-nginx Helm chart to deploy. https://artifacthub.io/packages/helm/ingress-nginx/ingress-nginx"
  type        = string
  default     = "4.12.3"
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
  description = "Ingress controller used to expose GoodData.CN. Use ingress-nginx for wildcard DNS, alb for Route53-managed ALB."
  type        = string
  default     = "ingress-nginx"
  validation {
    condition     = contains(["ingress-nginx", "alb"], var.ingress_controller)
    error_message = "ingress_controller must be either \"ingress-nginx\" or \"alb\"."
  }
}

variable "ingress_nginx_replica_count" {
  description = "Replica count for the ingress-nginx controller."
  type        = number
  default     = 1
}

variable "letsencrypt_email" {
  description = "Email address used for Let's Encrypt ACME registration (only required when ingress_controller = \"ingress-nginx\")"
  type        = string
  default     = ""
  validation {
    condition     = var.ingress_controller != "ingress-nginx" ? true : length(trimspace(var.letsencrypt_email)) > 0
    error_message = "letsencrypt_email must be provided when ingress_controller = \"ingress-nginx\"."
  }
}

variable "pulsar_bookkeeper_replica_count" {
  description = "Replica count for Pulsar bookkeeper."
  type        = number
  default     = 1
}

variable "pulsar_broker_replica_count" {
  description = "Replica count for Pulsar broker."
  type        = number
  default     = 1
}

variable "pulsar_zookeeper_replica_count" {
  description = "Replica count for Pulsar zookeeper."
  type        = number
  default     = 1
}

variable "rds_deletion_protection" {
  description = "Enable deletion protection on the RDS instance."
  type        = bool
  default     = true
}

variable "rds_instance_class" {
  description = "RDS PostgreSQL instance class"
  type        = string
  default     = "db.t4g.medium"
}

variable "rds_skip_final_snapshot" {
  description = "Skip taking a final snapshot when destroying the RDS instance."
  type        = bool
  default     = false
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID that will contain GoodData.CN records when using the ALB ingress option."
  type        = string
  default     = ""
  validation {
    condition     = var.ingress_controller != "alb" ? true : length(trimspace(var.route53_zone_id)) > 0
    error_message = "route53_zone_id is required when ingress_controller is \"alb\"."
  }
}

variable "wildcard_dns_provider" {
  description = "Wildcard DNS service used when exposing GoodData.CN via ingress-nginx. [default: sslip.io]"
  type        = string
  default     = "sslip.io"
}
