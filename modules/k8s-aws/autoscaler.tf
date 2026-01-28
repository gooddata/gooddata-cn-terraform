###
# Deploy cluster-autoscaler to Kubernetes
###

resource "kubernetes_namespace_v1" "cluster_autoscaler" {
  metadata {
    name = "cluster-autoscaler"
  }
}

# IRSA for Cluster Autoscaler
data "aws_iam_policy_document" "cluster_autoscaler_assume_role" {
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
      values   = ["system:serviceaccount:cluster-autoscaler:cluster-autoscaler-aws-cluster-autoscaler"]
    }
  }
}

resource "aws_iam_role" "cluster_autoscaler" {
  name               = "${var.deployment_name}-cluster-autoscaler"
  assume_role_policy = data.aws_iam_policy_document.cluster_autoscaler_assume_role.json
}

resource "aws_iam_role_policy" "cluster_autoscaler" {
  name   = "${var.deployment_name}-cluster-autoscaler-policy"
  role   = aws_iam_role.cluster_autoscaler.id
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:SetDesiredCapacity",
        "autoscaling:TerminateInstanceInAutoScalingGroup"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/k8s.io/cluster-autoscaler/enabled": "true",
          "aws:ResourceTag/k8s.io/cluster-autoscaler/${var.deployment_name}": "owned"
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeAutoScalingInstances",
        "autoscaling:DescribeLaunchConfigurations",
        "autoscaling:DescribeScalingActivities",
        "autoscaling:DescribeTags",
        "ec2:DescribeImages",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeLaunchTemplateVersions",
        "ec2:GetInstanceTypesFromInstanceRequirements",
        "eks:DescribeNodegroup"
      ],
      "Resource": "*"
    }
  ]
}
EOF
}

# Install Cluster Autoscaler via Helm
resource "helm_release" "cluster_autoscaler" {
  name          = "cluster-autoscaler"
  repository    = "https://kubernetes.github.io/autoscaler"
  chart         = "cluster-autoscaler"
  version       = var.helm_cluster_autoscaler_version
  namespace     = kubernetes_namespace_v1.cluster_autoscaler.metadata[0].name
  wait          = true
  wait_for_jobs = true
  timeout       = 1800

  # Values to configure Cluster Autoscaler
  values = [<<-EOF
image:
  repository: ${var.registry_k8sio}/autoscaling/cluster-autoscaler

rbac:
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: ${aws_iam_role.cluster_autoscaler.arn}
serviceAccount:
  create: true
  name: cluster-autoscaler
autoDiscovery:
  clusterName: ${var.deployment_name}
awsRegion: ${var.aws_region}
cloudProvider: aws
EOF
  ]
}
