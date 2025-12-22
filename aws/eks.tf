###
# Provision EKS cluster
###

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_name
}

# Allow nodes to create repositories (the first time an image is pulled through the cache)
resource "aws_iam_policy" "ecr_pull_through_cache_min" {
  count = var.enable_image_cache ? 1 : 0

  name        = "${var.deployment_name}-ECRPullThroughCacheMin"
  description = "Allow worker nodes to create ECR repositories and import upstream images via pull-through cache."

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "ecr:CreateRepository",
          "ecr:BatchImportUpstreamImage"
        ],
        Resource = "*"
      }
    ]
  })
}

locals {
  ecr_pull_through_cache_policy = var.enable_image_cache && length(aws_iam_policy.ecr_pull_through_cache_min) > 0 ? {
    ECRPullThroughCacheMin = aws_iam_policy.ecr_pull_through_cache_min[0].arn
  } : {}
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  cluster_name                         = var.deployment_name
  cluster_version                      = var.eks_version
  cluster_endpoint_public_access       = var.eks_endpoint_public_access
  cluster_endpoint_private_access      = var.eks_endpoint_private_access
  cluster_endpoint_public_access_cidrs = var.eks_endpoint_public_access_cidrs

  tags = local.common_tags

  cluster_addons = {
    coredns                = {}
    eks-pod-identity-agent = {}
    kube-proxy             = {}
    vpc-cni                = {}
    aws-ebs-csi-driver     = {}
  }

  # Adds the current caller identity as an administrator via cluster access entry
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    nodes = {
      ami_type                   = "BOTTLEROCKET_x86_64"
      instance_types             = var.eks_node_types
      use_custom_launch_template = false
      disk_size                  = 100

      # Tags required by cluster-autoscaler autodiscovery and IAM conditions
      tags = merge(
        local.common_tags,
        {
          "k8s.io/cluster-autoscaler/enabled"                = "true"
          "k8s.io/cluster-autoscaler/${var.deployment_name}" = "owned"
        }
      )

      iam_role_additional_policies = merge({
        AmazonEBSCSIDriverPolicy           = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
        AmazonEC2ContainerRegistryPullOnly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
      }, local.ecr_pull_through_cache_policy)

      min_size = 1
      max_size = var.eks_max_nodes

      # This value is ignored after the initial creation
      # https://github.com/bryantbiggs/eks-desired-size-hack
      desired_size = 2
    }
  }

  node_security_group_additional_rules = var.ingress_controller == "istio_gateway" ? {
    istio_xds = {
      description                   = "Istio XDS (istiod) to workloads"
      protocol                      = "tcp"
      from_port                     = 15012
      to_port                       = 15012
      type                          = "ingress"
      source_cluster_security_group = true
    }
    istio_webhook = {
      description                   = "Istio webhook/istiod"
      protocol                      = "tcp"
      from_port                     = 15017
      to_port                       = 15017
      type                          = "ingress"
      source_cluster_security_group = true
    }
  } : {}
}

# Outputs
output "eks_cluster_name" {
  description = "Name of the EKS cluster"
  value       = module.eks.cluster_name
}
