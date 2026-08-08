###
# Provision Karpenter
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

  # The generated controller policy exceeds the 6144-char managed-policy quota.
  # Inline role policies allow 10240, which fits.
  enable_inline_policy = true

  # Lets Karpenter-launched nodes pull images (incl. via the optional
  # pull-through cache). Same policy set as the system node group.
  node_iam_role_additional_policies = local.node_iam_role_additional_policies

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
    # The chart's default 2 replicas require hostname anti-affinity to be
    # satisfiable, so one system node means one replica.
    replicas = min(local.system_node_count, 2)
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
    # Run on the isolated system node group (CriticalAddonsOnly taint, eks.tf).
    tolerations = [{ key = "CriticalAddonsOnly", operator = "Exists" }]
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
      # Bottlerocket's default 20 GiB /dev/xvdb is below the ephemeral-storage
      # some pods request, leaving them unschedulable on every instance type.
      blockDeviceMappings = [{
        deviceName = "/dev/xvdb"
        ebs = {
          volumeSize          = "${var.eks_node_disk_size}Gi"
          volumeType          = "gp3"
          encrypted           = true
          deleteOnTermination = true
        }
      }]
      # Karpenter sizes maxPods from secondary-IP limits, leaving prefix
      # delegation (eks.tf) inert. 110 fits every node these pools build.
      kubelet = {
        maxPods = var.eks_node_max_pods
      }
    }
  })

  depends_on = [helm_release.karpenter]
}

# General-purpose NodePool: on-demand AMD m category (modern gens) with a
# per-node vCPU cap (size-profiles.tf). Category "m" is inherently 4 GiB/vCPU
# general-purpose (no low-memory variants); instance-cpu-manufacturer pins AMD
# (m*a) to drop Intel (m*i), matching the AMD-only, 4 GiB/vCPU fleet on Azure.
# A broad category (not an explicit type list) within AMD still maximizes
# capacity resilience; instance-cpu + the CPU limit bound size and cost.
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
            { key = "karpenter.k8s.aws/instance-category", operator = "In", values = ["m"] },
            { key = "karpenter.k8s.aws/instance-cpu-manufacturer", operator = "In", values = ["amd"] },
            { key = "karpenter.k8s.aws/instance-generation", operator = "Gt", values = ["5"] },
            { key = "karpenter.k8s.aws/instance-cpu", operator = "Lt", values = [tostring(local.eks_node_cpu_max + 1)] },
          ]
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default"
          }
          expireAfter = "720h"
        }
      }
      # Total vCPU ceiling for this NodePool (size-profiles.tf). StarRocks pool
      # below is uncapped (bounded by fixed replicas).
      limits = {
        cpu = local.eks_node_cpu_limit
      }
      # 15m of underutilization before reclaiming a node, so bursty workloads
      # do not churn capacity.
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "15m"
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
            { key = "node.kubernetes.io/instance-type", operator = "In", values = local.eks_ai_lake_node_types },
          ]
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default"
          }
          expireAfter = "720h"
        }
      }
      # WhenEmpty (not WhenEmptyOrUnderutilized like the general pool): StarRocks
      # FE/CN are stateful with zonal EBS volumes, so only reclaim truly empty
      # nodes rather than consolidating/evicting running stateful pods.
      disruption = {
        consolidationPolicy = "WhenEmpty"
        consolidateAfter    = "1m"
      }
    }
  })

  depends_on = [kubectl_manifest.karpenter_node_class]
}
