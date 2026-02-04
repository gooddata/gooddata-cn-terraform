###
# Deploy Karpenter to Kubernetes
###

# Data source to get AWS partition (aws, aws-cn, aws-us-gov)
data "aws_partition" "current" {}

# Data source to get current AWS region
data "aws_region" "current" {}

###
# IAM Role for Karpenter-provisioned nodes
###

# Trust policy allowing EC2 to assume this role
data "aws_iam_policy_document" "karpenter_node_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# IAM Role for Karpenter-provisioned EC2 nodes
resource "aws_iam_role" "karpenter_node" {
  name               = "${var.deployment_name}-karpenter-node"
  assume_role_policy = data.aws_iam_policy_document.karpenter_node_assume_role.json

  tags = {
    "karpenter.sh/discovery" = var.deployment_name
  }
}

# Attach required managed policies to the node role
resource "aws_iam_role_policy_attachment" "karpenter_node_eks_worker" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_eks_cni" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ecr_readonly" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ebs_csi" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# Optional: ECR pull-through cache policy (if enabled)
resource "aws_iam_role_policy_attachment" "karpenter_node_ecr_pull_through" {
  count      = var.ecr_pull_through_cache_policy_arn != "" ? 1 : 0
  role       = aws_iam_role.karpenter_node.name
  policy_arn = var.ecr_pull_through_cache_policy_arn
}

###
# IRSA for Karpenter Controller
###

# IRSA for Karpenter
data "aws_iam_policy_document" "karpenter_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.eks_cluster_oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(var.eks_cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:karpenter"]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(var.eks_cluster_oidc_issuer_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "karpenter" {
  name               = "${var.deployment_name}-karpenter"
  assume_role_policy = data.aws_iam_policy_document.karpenter_assume_role.json
}

# IAM Policy for Karpenter Controller
resource "aws_iam_role_policy" "karpenter_controller" {
  name = "${var.deployment_name}-karpenter-policy"
  role = aws_iam_role.karpenter.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Allow Karpenter to create and manage EC2 instances with specific tags
      {
        Sid    = "AllowScopedEC2InstanceAccessActions"
        Effect = "Allow"
        Action = [
          "ec2:RunInstances",
          "ec2:CreateFleet"
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.id}::image/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.id}::snapshot/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.id}:*:security-group/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.id}:*:subnet/*"
        ]
      },
      {
        Sid    = "AllowScopedEC2LaunchTemplateAccessActions"
        Effect = "Allow"
        Action = [
          "ec2:RunInstances",
          "ec2:CreateFleet"
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.id}:*:launch-template/*"
        ]
        Condition = {
          StringEquals = {
            "aws:ResourceTag/karpenter.sh/discovery" = var.deployment_name
          }
        }
      },
      {
        Sid    = "AllowScopedEC2InstanceActionsWithTags"
        Effect = "Allow"
        Action = [
          "ec2:RunInstances",
          "ec2:CreateFleet",
          "ec2:CreateLaunchTemplate"
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.id}:*:fleet/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.id}:*:instance/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.id}:*:volume/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.id}:*:network-interface/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.id}:*:launch-template/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.id}:*:spot-instances-request/*"
        ]
        Condition = {
          StringEquals = {
            "aws:RequestTag/karpenter.sh/discovery" = var.deployment_name
          }
        }
      },
      {
        Sid    = "AllowScopedResourceCreationTagging"
        Effect = "Allow"
        Action = "ec2:CreateTags"
        Resource = [
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.id}:*:fleet/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.id}:*:instance/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.id}:*:volume/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.id}:*:network-interface/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.id}:*:launch-template/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.id}:*:spot-instances-request/*"
        ]
        Condition = {
          StringEquals = {
            "aws:RequestTag/karpenter.sh/discovery" = var.deployment_name
            "ec2:CreateAction" = [
              "RunInstances",
              "CreateFleet",
              "CreateLaunchTemplate"
            ]
          }
        }
      },
      {
        Sid      = "AllowScopedResourceTagging"
        Effect   = "Allow"
        Action   = "ec2:CreateTags"
        Resource = "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.id}:*:instance/*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/karpenter.sh/discovery" = var.deployment_name
          }
          ForAllValues = {
            StringEquals = {
              "aws:TagKeys" = ["karpenter.sh/nodeclaim", "Name"]
            }
          }
        }
      },
      {
        Sid    = "AllowScopedDeletion"
        Effect = "Allow"
        Action = [
          "ec2:TerminateInstances",
          "ec2:DeleteLaunchTemplate"
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.id}:*:instance/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.id}:*:launch-template/*"
        ]
        Condition = {
          StringEquals = {
            "aws:ResourceTag/karpenter.sh/discovery" = var.deployment_name
          }
        }
      },
      # Read-only permissions
      {
        Sid    = "AllowRegionalReadActions"
        Effect = "Allow"
        Action = [
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeImages",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeSubnets"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestedRegion" = data.aws_region.current.id
          }
        }
      },
      {
        Sid      = "AllowSSMReadActions"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.id}::parameter/aws/service/*"
      },
      {
        Sid    = "AllowPricingReadActions"
        Effect = "Allow"
        Action = "pricing:GetProducts"
        # Pricing API is only available in us-east-1 and ap-south-1
        Resource = "*"
      },
      # EKS permissions
      {
        Sid      = "AllowEKSClusterReadActions"
        Effect   = "Allow"
        Action   = "eks:DescribeCluster"
        Resource = "arn:${data.aws_partition.current.partition}:eks:${data.aws_region.current.id}:*:cluster/${var.deployment_name}"
      },
      # IAM permissions for instance profiles
      {
        Sid      = "AllowPassingInstanceRole"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.karpenter_node.arn
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ec2.amazonaws.com"
          }
        }
      },
      {
        Sid    = "AllowScopedInstanceProfileCreationActions"
        Effect = "Allow"
        Action = [
          "iam:CreateInstanceProfile"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:iam::*:instance-profile/*"
        Condition = {
          StringEquals = {
            "aws:RequestTag/karpenter.sh/discovery"                       = var.deployment_name
            "aws:RequestTag/kubernetes.io/cluster/${var.deployment_name}" = "owned"
          }
        }
      },
      {
        Sid      = "AllowScopedInstanceProfileTagActions"
        Effect   = "Allow"
        Action   = "iam:TagInstanceProfile"
        Resource = "arn:${data.aws_partition.current.partition}:iam::*:instance-profile/*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/karpenter.sh/discovery"                       = var.deployment_name
            "aws:ResourceTag/kubernetes.io/cluster/${var.deployment_name}" = "owned"
            "aws:RequestTag/karpenter.sh/discovery"                        = var.deployment_name
            "aws:RequestTag/kubernetes.io/cluster/${var.deployment_name}"  = "owned"
          }
        }
      },
      {
        Sid    = "AllowScopedInstanceProfileActions"
        Effect = "Allow"
        Action = [
          "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile",
          "iam:DeleteInstanceProfile"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:iam::*:instance-profile/*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/karpenter.sh/discovery"                       = var.deployment_name
            "aws:ResourceTag/kubernetes.io/cluster/${var.deployment_name}" = "owned"
          }
        }
      },
      {
        Sid      = "AllowInstanceProfileReadActions"
        Effect   = "Allow"
        Action   = "iam:GetInstanceProfile"
        Resource = "arn:${data.aws_partition.current.partition}:iam::*:instance-profile/*"
      }
    ]
  })
}

# Install Karpenter via Helm
resource "helm_release" "karpenter" {
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = var.helm_karpenter_version
  namespace        = "kube-system"
  create_namespace = false
  wait             = true
  wait_for_jobs    = true
  timeout          = 1800

  values = [<<-EOF
settings:
  clusterName: ${var.deployment_name}
  clusterEndpoint: ${var.eks_cluster_endpoint}
  interruptionQueue: ""
serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: ${aws_iam_role.karpenter.arn}
# Use Default DNS policy for Fargate - host DNS resolution
# This avoids chicken-and-egg with CoreDNS on Fargate
dnsPolicy: Default
controller:
  resources:
    requests:
      cpu: 1
      memory: 1Gi
    limits:
      cpu: 1
      memory: 1Gi
EOF
  ]

  depends_on = [
    aws_iam_role_policy.karpenter_controller
  ]
}

# Deploy NodePool CRD
resource "kubectl_manifest" "karpenter_node_pool" {
  yaml_body = <<-YAML
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c", "m", "r"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["2"]
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      expireAfter: 720h
  limits:
    cpu: ${var.karpenter_cpu_limit}
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
YAML

  depends_on = [
    helm_release.karpenter
  ]
}

# Deploy EC2NodeClass CRD
resource "kubectl_manifest" "karpenter_ec2_node_class" {
  yaml_body = <<-YAML
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  role: ${aws_iam_role.karpenter_node.name}
  amiSelectorTerms:
    - alias: bottlerocket@latest
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${var.deployment_name}
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${var.deployment_name}
  tags:
    karpenter.sh/discovery: ${var.deployment_name}
YAML

  depends_on = [
    helm_release.karpenter,
    aws_iam_role.karpenter_node,
  ]
}
