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

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name                         = var.deployment_name
  cluster_version                      = var.eks_version
  cluster_endpoint_public_access       = var.eks_endpoint_public_access
  cluster_endpoint_private_access      = var.eks_endpoint_private_access
  cluster_endpoint_public_access_cidrs = var.eks_endpoint_public_access_cidrs

  tags = local.common_tags

  cluster_addons = {
    coredns = {
      # Configure CoreDNS to run on Fargate
      configuration_values = jsonencode({
        computeType = "Fargate"
      })
    }
    eks-pod-identity-agent = {}
    kube-proxy             = {}
    vpc-cni                = {}
    aws-ebs-csi-driver     = {}
  }

  # Adds the current caller identity as an administrator via cluster access entry
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Fargate profiles for Karpenter and CoreDNS (bootstrap components)
  # All other workloads will run on Karpenter-provisioned EC2 nodes
  fargate_profiles = {
    karpenter = {
      name = "karpenter"
      selectors = [
        {
          namespace = "kube-system"
          labels = {
            "app.kubernetes.io/name" = "karpenter"
          }
        }
      ]
    }
    coredns = {
      name = "coredns"
      selectors = [
        {
          namespace = "kube-system"
          labels = {
            "k8s-app" = "kube-dns"
          }
        }
      ]
    }
  }

  # Create node security group for Karpenter-provisioned nodes
  create_node_security_group = true

  # Tag node security group for Karpenter discovery
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

output "eks_cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = module.eks.cluster_endpoint
}
