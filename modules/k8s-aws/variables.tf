variable "aws_region" { type = string }

variable "deployment_name" { type = string }

variable "dns_provider" { type = string }

variable "eks_cluster_endpoint" { type = string }

variable "eks_cluster_oidc_issuer_url" { type = string }

variable "eks_cluster_oidc_provider_arn" { type = string }

variable "ecr_pull_through_cache_policy_arn" {
  description = "ARN of the ECR pull-through cache IAM policy (optional)"
  type        = string
  default     = ""
}

variable "helm_aws_lb_controller_version" { type = string }

variable "helm_external_dns_version" { type = string }

variable "helm_karpenter_version" { type = string }

variable "helm_metrics_server_version" { type = string }

variable "ingress_controller" { type = string }

variable "karpenter_cpu_limit" { type = number }

variable "registry_k8sio" { type = string }

variable "route53_zone_id" { type = string }

variable "size_profile" { type = string }

variable "vpc_id" { type = string }
