###
# Provision Karpenter (replaces cluster-autoscaler)
#
# Karpenter provisions right-sized, on-demand EC2 capacity just-in-time in
# response to pending pods. The supporting IAM roles, instance profile, SQS
# interruption queue and EKS Pod Identity association are created by the
# upstream eks/karpenter submodule; the controller is installed via Helm and
# the provisioning policy is expressed as an EC2NodeClass + NodePool(s).
###

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.0"

  cluster_name = module.eks.cluster_name

  # v21 defaults to EKS Pod Identity (the pod-identity agent add-on is enabled
  # on the cluster) and v1 (>= 1.0) controller permissions; we just create the
  # association binding the kube-system/karpenter service account to the role.
  create_pod_identity_association = true

  # Node role gets the same managed policies the old cluster-autoscaler node
  # groups carried, so Karpenter-launched nodes can use the EBS CSI driver and
  # pull images (incl. via the optional pull-through cache).
  node_iam_role_additional_policies = merge({
    AmazonEBSCSIDriverPolicy           = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
    AmazonEC2ContainerRegistryPullOnly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
  }, local.ecr_pull_through_cache_policy)

  tags = local.common_tags
}

# Install the Karpenter controller into kube-system (runs on the fixed-size
# system node group defined in eks.tf).
resource "helm_release" "karpenter" {
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.helm_karpenter_version
  namespace  = "kube-system"

  wait    = true
  timeout = 1800

  values = [yamlencode({
    serviceAccount = {
      name = "karpenter"
    }
    settings = {
      clusterName       = module.eks.cluster_name
      clusterEndpoint   = module.eks.cluster_endpoint
      interruptionQueue = module.karpenter.queue_name
    }
    controller = {
      resources = {
        requests = { cpu = "1", memory = "1Gi" }
        limits   = { memory = "1Gi" }
      }
    }
  })]

  depends_on = [module.eks, module.karpenter]
}

# EC2NodeClass: how Karpenter builds nodes (Bottlerocket AMI, node IAM role,
# subnet/SG discovery by the karpenter.sh/discovery tag set in vpc.tf/eks.tf).
resource "kubectl_manifest" "karpenter_node_class" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "default"
    }
    spec = {
      amiFamily        = "Bottlerocket"
      role             = module.karpenter.node_iam_role_name
      amiSelectorTerms = [{ alias = "bottlerocket@latest" }]
      subnetSelectorTerms = [{
        tags = { "karpenter.sh/discovery" = var.deployment_name }
      }]
      securityGroupSelectorTerms = [{
        tags = { "karpenter.sh/discovery" = var.deployment_name }
      }]
      tags = merge(local.common_tags, {
        "karpenter.sh/discovery" = var.deployment_name
      })
    }
  })

  depends_on = [helm_release.karpenter]
}

# General-purpose NodePool: on-demand only, constrained to the instance types
# from the active size profile (size-profiles.tf). Mirrors the least-waste
# behaviour of the old per-instance-type cluster-autoscaler node groups —
# Karpenter picks the cheapest instance that fits the pending pods.
resource "kubectl_manifest" "karpenter_node_pool" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "general"
    }
    spec = {
      template = {
        spec = {
          requirements = [
            { key = "kubernetes.io/arch", operator = "In", values = ["amd64"] },
            { key = "kubernetes.io/os", operator = "In", values = ["linux"] },
            { key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] },
            { key = "node.kubernetes.io/instance-type", operator = "In", values = local.eks_node_types },
          ]
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default"
          }
          expireAfter = "720h"
        }
      }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "1m"
      }
    }
  })

  depends_on = [kubectl_manifest.karpenter_node_class]
}

# StarRocks NodePool: dedicated taint+label so FE/CN pods are isolated, on the
# StarRocks instance types from the size profile. Zonal placement (EBS is
# zonal) is handled automatically by Karpenter via volume topology, so no
# per-AZ pools are needed.
resource "kubectl_manifest" "karpenter_node_pool_starrocks" {
  count = var.enable_ai_lake ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "starrocks"
    }
    spec = {
      template = {
        metadata = {
          labels = { workload = "starrocks" }
        }
        spec = {
          taints = [{
            key    = "workload"
            value  = "starrocks"
            effect = "NoSchedule"
          }]
          requirements = [
            { key = "kubernetes.io/arch", operator = "In", values = ["amd64"] },
            { key = "kubernetes.io/os", operator = "In", values = ["linux"] },
            { key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] },
            { key = "node.kubernetes.io/instance-type", operator = "In", values = local.eks_starrocks_node_types },
          ]
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default"
          }
          expireAfter = "720h"
        }
      }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "1m"
      }
    }
  })

  depends_on = [kubectl_manifest.karpenter_node_class]
}
