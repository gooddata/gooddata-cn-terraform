###
# Deploy all AWS-specific Kubernetes resources
###

module "k8s_aws" {
  source = "../modules/k8s-aws"

  providers = {
    kubernetes = kubernetes
    helm       = helm
  }

  deployment_name    = var.deployment_name
  aws_region         = var.aws_region
  ingress_controller = var.ingress_controller
  dns_provider       = var.dns_provider
  route53_zone_id    = var.route53_zone_id
  size_profile       = var.size_profile

  registry_k8sio = local.registry_k8sio

  helm_cluster_autoscaler_version = var.helm_cluster_autoscaler_version
  helm_aws_lb_controller_version  = var.helm_aws_lb_controller_version
  helm_metrics_server_version     = var.helm_metrics_server_version
  helm_external_dns_version       = var.helm_external_dns_version

  vpc_id                        = module.vpc.vpc_id
  eks_cluster_oidc_provider_arn = module.eks.oidc_provider_arn
  eks_cluster_oidc_issuer_url   = module.eks.cluster_oidc_issuer_url
}
