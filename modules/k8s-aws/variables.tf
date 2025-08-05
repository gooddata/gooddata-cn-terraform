variable "deployment_name" { type = string }
variable "aws_region" { type = string }

variable "cache_registryk8sio" { type = string }

variable "helm_cluster_autoscaler_version" { type = string }
variable "helm_ingress_nginx_version" { type = string }
variable "helm_aws_lb_controller_version" { type = string }

variable "vpc_id" { type = string }
variable "eip_allocations" { type = string }
variable "eks_cluster_oidc_provider_arn" { type = string }
variable "eks_cluster_oidc_issuer_url" { type = string }
