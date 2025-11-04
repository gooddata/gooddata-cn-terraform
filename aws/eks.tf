###
# Provision EKS cluster
###

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_name
}

# Allow nodes to create repositories (the first time an image is pulled through the cache)
resource "aws_iam_policy" "ecr_pull_through_cache_min" {
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

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name                   = var.deployment_name
  cluster_version                = var.eks_version
  cluster_endpoint_public_access = true

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

      iam_role_additional_policies = {
        AmazonEBSCSIDriverPolicy           = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
        AmazonEC2ContainerRegistryPullOnly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
        ECRPullThroughCacheMin             = aws_iam_policy.ecr_pull_through_cache_min.arn
      }

      min_size = 1
      max_size = var.eks_max_nodes

      # This value is ignored after the initial creation
      # https://github.com/bryantbiggs/eks-desired-size-hack
      desired_size = 2
    }
  }

  depends_on = [
    module.vpc
  ]
}

# Outputs
output "eks_cluster_name" {
  description = "Name of the EKS cluster"
  value       = module.eks.cluster_name
}
