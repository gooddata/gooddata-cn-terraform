###
# Deploy all AWS-specific Kubernetes resources
###

module "k8s_aws" {
  source = "../modules/k8s-aws"

  providers = {
    kubernetes = kubernetes
    helm       = helm
  }

  deployment_name = var.deployment_name
  aws_region      = var.aws_region

  registry_k8sio = local.registry_k8sio

  helm_cluster_autoscaler_version = var.helm_cluster_autoscaler_version
  helm_ingress_nginx_version      = var.helm_ingress_nginx_version
  helm_aws_lb_controller_version  = var.helm_aws_lb_controller_version

  vpc_id                        = module.vpc.vpc_id
  eip_allocations               = join(",", aws_eip.lb[*].allocation_id)
  eks_cluster_oidc_provider_arn = module.eks.oidc_provider_arn
  eks_cluster_oidc_issuer_url   = module.eks.cluster_oidc_issuer_url

  depends_on = [
    module.eks,
    aws_ecr_pull_through_cache_rule.k8sio
  ]
}
