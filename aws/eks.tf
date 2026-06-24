###
# Provision EKS cluster
###

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

  # Node sizing / StarRocks node types: resolved in size-profiles.tf and applied
  # via Karpenter NodePools (see karpenter.tf), not managed node groups.
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name                         = var.deployment_name
  kubernetes_version           = var.eks_version
  endpoint_public_access       = var.eks_endpoint_public_access
  endpoint_private_access      = var.eks_endpoint_private_access
  endpoint_public_access_cidrs = var.eks_endpoint_public_access_cidrs

  tags = local.common_tags

  addons = {
    coredns = {
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    eks-pod-identity-agent = {}
    kube-proxy             = {}
    vpc-cni = {
      before_compute = true
    }
    aws-ebs-csi-driver = {
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
  }

  # Adds the current caller identity as an administrator via cluster access entry
  enable_cluster_creator_admin_permissions = true

  vpc_id     = local.vpc_id
  subnet_ids = local.private_subnet_ids

  # A single small, fixed-size managed node group hosts the Karpenter
  # controller and cluster-critical add-ons. Karpenter (see karpenter.tf) then
  # provisions all workload capacity just-in-time, replacing the per-instance
  # -type cluster-autoscaler node groups (general + StarRocks) that used to
  # live here.
  eks_managed_node_groups = {
    system = {
      ami_type                   = "BOTTLEROCKET_x86_64"
      instance_types             = [local.eks_node_types[0]]
      use_custom_launch_template = false
      disk_size                  = 100

      tags = local.common_tags

      iam_role_additional_policies = merge({
        AmazonEBSCSIDriverPolicy           = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
        AmazonEC2ContainerRegistryPullOnly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
      }, local.ecr_pull_through_cache_policy)

      min_size     = 2
      max_size     = 3
      desired_size = 2
    }
  }

  # Tag the node security group so the Karpenter EC2NodeClass can discover it
  # via securityGroupSelectorTerms.
  node_security_group_tags = {
    "karpenter.sh/discovery" = var.deployment_name
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
