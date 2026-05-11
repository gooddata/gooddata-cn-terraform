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

  eks_node_type_presets = {
    dev        = ["m6a.xlarge", "m6a.2xlarge"]
    prod-small = ["m8a.xlarge", "m8a.2xlarge"]
    prod-xl    = ["m8a.xlarge", "m8a.2xlarge", "m8a.4xlarge"]
  }

  eks_starrocks_node_type_presets = {
    dev        = ["r8a.large", "m8a.xlarge"]
    prod-small = ["r8a.large", "r8a.xlarge"]
    prod-xl    = ["r8a.large", "r8a.8xlarge"]
  }

  eks_node_types           = coalesce(var.eks_node_types, local.eks_node_type_presets[var.size_profile])
  eks_starrocks_node_types = coalesce(var.eks_starrocks_node_types, local.eks_starrocks_node_type_presets[coalesce(var.starrocks_size_profile, var.size_profile)])
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

  # One node group per instance type so the cluster autoscaler can
  # independently evaluate and scale each size (least-waste expander).
  # StarRocks gets a dedicated taint+label pool so FE/CN pods are isolated
  # from the shared workload pool.
  eks_managed_node_groups = merge(
    {
      for instance_type in local.eks_node_types : replace(instance_type, ".", "-") => {
        create                     = true
        ami_type                   = "BOTTLEROCKET_x86_64"
        instance_types             = [instance_type]
        use_custom_launch_template = false
        disk_size                  = 100

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

        min_size = 0
        max_size = var.eks_max_nodes

        # This value is ignored after the initial creation
        # https://github.com/bryantbiggs/eks-desired-size-hack
        desired_size = instance_type == local.eks_node_types[0] ? 1 : 0
      }
    },
    {
      for instance_type in local.eks_starrocks_node_types : "sr-${replace(instance_type, ".", "-")}" => {
        create                     = true
        ami_type                   = "BOTTLEROCKET_x86_64"
        instance_types             = [instance_type]
        use_custom_launch_template = false
        disk_size                  = 100

        labels = {
          workload = "starrocks"
        }
        taints = {
          starrocks = {
            key    = "workload"
            value  = "starrocks"
            effect = "NO_SCHEDULE"
          }
        }

        tags = merge(
          local.common_tags,
          {
            "k8s.io/cluster-autoscaler/enabled"                      = "true"
            "k8s.io/cluster-autoscaler/${var.deployment_name}"       = "owned"
            "k8s.io/cluster-autoscaler/node-template/label/workload" = "starrocks"
            "k8s.io/cluster-autoscaler/node-template/taint/workload" = "starrocks:NoSchedule"
          }
        )

        iam_role_additional_policies = merge({
          AmazonEBSCSIDriverPolicy           = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
          AmazonEC2ContainerRegistryPullOnly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
        }, local.ecr_pull_through_cache_policy)

        min_size     = 0
        max_size     = var.eks_max_nodes
        desired_size = 0
      }
    },
  )

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
