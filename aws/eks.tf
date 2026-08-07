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

  # Managed policies shared by every node role (system managed node group here,
  # and the Karpenter node role in karpenter.tf): image pull, plus the
  # pull-through cache policy when image caching is enabled. EBS volume calls
  # are made by the CSI controller, which gets AmazonEBSCSIDriverPolicy through
  # aws_iam_role.ebs_csi_irsa — nodes do not need it.
  node_iam_role_additional_policies = merge({
    AmazonEC2ContainerRegistryPullOnly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
  }, local.ecr_pull_through_cache_policy)

  # Node sizing / AI Lake node types: resolved in size-profiles.tf and applied
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
      # Tolerate the system pool's CriticalAddonsOnly taint so CoreDNS still
      # runs there once the pool is isolated (see system node group below).
      configuration_values = jsonencode({
        tolerations = [{ key = "CriticalAddonsOnly", operator = "Exists" }]
      })
    }
    eks-pod-identity-agent = {}
    kube-proxy             = {}
    vpc-cni = {
      before_compute = true
      # Prefix delegation: each ENI slot carries a /28, not one IP, so pod
      # density stops tracking instance size. maxPods pinned to match below.
      configuration_values = jsonencode({
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    aws-ebs-csi-driver = {
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
      service_account_role_arn    = aws_iam_role.ebs_csi_irsa.arn
    }
  }

  # Adds the current caller identity as an administrator via cluster access entry
  enable_cluster_creator_admin_permissions = true

  vpc_id     = local.vpc_id
  subnet_ids = local.private_subnet_ids

  # A single small, fixed-size managed node group hosts the Karpenter controller
  # and cluster-critical add-ons; Karpenter (karpenter.tf) provisions all
  # workload capacity just-in-time.
  eks_managed_node_groups = {
    system = {
      ami_type       = "BOTTLEROCKET_x86_64"
      instance_types = [local.system_node_type]

      # A custom launch template is what puts these nodes in the shared node
      # security group. Bottlerocket stores containers on /dev/xvdb.
      block_device_mappings = {
        xvdb = {
          device_name = "/dev/xvdb"
          ebs = {
            volume_size           = var.eks_node_disk_size
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      # Without this the kubelet keeps the secondary-IP pod limit, leaving
      # prefix delegation inert here. EKS merges this with its own TOML.
      bootstrap_extra_args = <<-EOT
        [settings.kubernetes]
        max-pods = ${var.eks_node_max_pods}
      EOT

      # Isolate the system pool: only system pods (which tolerate this taint)
      # run here; all workloads go to Karpenter-provisioned nodes. CoreDNS
      # (addon above) and Karpenter (karpenter.tf) are given matching tolerations.
      taints = {
        CriticalAddonsOnly = {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }

      tags = local.common_tags

      iam_role_additional_policies = local.node_iam_role_additional_policies

      # Sized per size_profile (size-profiles.tf), matching AKS. One spare slot
      # above desired so a node can be replaced without losing capacity.
      min_size     = local.system_node_count
      max_size     = local.system_node_count + 1
      desired_size = local.system_node_count
    }
  }

  # Tag the node security group so the Karpenter EC2NodeClass can discover it
  # via securityGroupSelectorTerms.
  node_security_group_tags = {
    "karpenter.sh/discovery" = var.deployment_name
  }

  # Pod IPs live on node ENIs, so this group governs all pod-to-pod traffic.
  node_security_group_additional_rules = merge({
    node_to_node_all = {
      description = "Node to node, all ports and protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    }, var.ingress_controller == "istio_gateway" ? {
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
  } : {})
}

# Outputs
output "eks_cluster_name" {
  description = "Name of the EKS cluster"
  value       = module.eks.cluster_name
}
