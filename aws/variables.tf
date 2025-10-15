variable "aws_profile_name" {
  description = "Name of AWS profile defined in ~/.aws/config to be used by Terraform."
  type        = string
}

variable "aws_region" {
  description = "AWS region to deploy resources to."
  type        = string
  default     = "us-east-2"
}

variable "aws_additional_tags" {
  description = "Map of additional tags to apply to all AWS resources"
  type        = map(string)
  default     = {}
}

variable "deployment_name" {
  description = "Name prefix for all AWS resources."
  type        = string
  default     = "gooddata-cn"
  validation {
    condition = can(regex("^[a-z](?:[a-z0-9-]*[a-z0-9])?$", var.deployment_name))
    error_message = "deployment_name must be lowercase, start with a letter, contain only letters, numbers, and hyphens, and must not end with a hyphen."
  }
}

variable "dockerhub_username" {
  description = "Docker Hub username (used to pull images without hitting rate limits). Free account is enough."
  type        = string
  default     = ""
  validation {
    condition     = var.ecr_cache_images ? length(var.dockerhub_username) > 0 : true
    error_message = "dockerhub_username must be provided when ecr_cache_images is true."
  }
}

variable "dockerhub_access_token" {
  description = "Docker Hub access token (can be created in Settings > Personal Access Tokens)"
  type        = string
  default     = ""
  validation {
    condition     = var.ecr_cache_images ? length(var.dockerhub_access_token) > 0 : true
    error_message = "dockerhub_access_token must be provided when ecr_cache_images is true."
  }
}

variable "ecr_cache_images" {
  description = "If true, ECR pull-through cache rules will be created and all services configured to use it. If false, images are pulled from their original registries."
  type        = bool
  default     = false
}

variable "eks_version" {
  description = "Version of EKS to deploy."
  type        = string
  default     = "1.33"
}

variable "eks_node_types" {
  description = "List of EC2 instance types for EKS worker nodes"
  type        = list(string)
  default     = ["m6i.xlarge"]
}

variable "eks_max_nodes" {
  description = "Maximum number of EKS worker nodes"
  type        = number
  default     = 10
}

variable "rds_instance_class" {
  description = "RDS PostgreSQL instance class"
  type        = string
  default     = "db.t4g.medium"
}

variable "gdcn_license_key" {
  description = "GoodData.CN license key (provided by your GoodData contact)"
  type        = string
  sensitive   = true
}

variable "letsencrypt_email" {
  description = "Email address used for Let's Encrypt ACME registration"
  type        = string
}

variable "wildcard_dns_provider" {
  description = "Wildcard DNS service used to give a dynamic hostname for hosting GoodData.CN. [default: sslip.io]"
  type        = string
  default     = "sslip.io"
}

variable "gdcn_replica_count" {
  description = "Replica count for GoodData.CN components (passed to the chart)."
  type        = number
  default     = 2
}

variable "helm_cluster_autoscaler_version" {
  description = "Version of the cluster-autoscaler Helm chart to deploy. https://artifacthub.io/packages/helm/cluster-autoscaler/cluster-autoscaler"
  type        = string
  default     = "9.46.6"
}

variable "helm_ingress_nginx_version" {
  description = "Version of the ingress-nginx Helm chart to deploy. https://artifacthub.io/packages/helm/ingress-nginx/ingress-nginx"
  type        = string
  default     = "4.12.3"
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

variable "helm_metrics_server_version" {
  description = "Version of the metrics-server Helm chart to deploy. https://artifacthub.io/packages/helm/metrics-server/metrics-server"
  type        = string
  default     = "3.13.0"
}

variable "helm_gdcn_version" {
  description = "Version of the gooddata-cn Helm chart to deploy. https://artifacthub.io/packages/helm/gooddata-cn/gooddata-cn"
  type        = string
}

variable "helm_pulsar_version" {
  description = "Version of the pulsar Helm chart to deploy. https://artifacthub.io/packages/helm/apache/pulsar"
  type        = string
  default     = "3.9.0"
}
