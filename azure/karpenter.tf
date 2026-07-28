###
# Karpenter provisioning policy for Node Auto Provisioning (NAP)
#
# NAP (enabled on the cluster in aks.tf) installs and manages the Karpenter
# controller and its CRDs in the AKS control plane. We only supply the
# provisioning policy: an AKSNodeClass (how nodes are built) and a NodePool
# (what may be provisioned). Because the cluster sets default_node_pools=None,
# these are the only NodePools.
###

# How NAP builds nodes: Ubuntu 22.04 image, 100 GB OS disk.
resource "kubectl_manifest" "karpenter_node_class" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.azure.com/v1beta1"
    kind       = "AKSNodeClass"
    metadata = {
      name = "default"
    }
    spec = {
      imageFamily  = "Ubuntu2204"
      osDiskSizeGB = 100
    }
  })

  depends_on = [
    azurerm_kubernetes_cluster.main,
    azurerm_role_assignment.aks_creator_cluster_admin,
  ]
}

# General-purpose NodePool: on-demand AMD general-purpose D-series with a
# per-node vCPU cap (size-profiles.tf). We pin sku-series (not the broad "D"
# family) to keep the fleet homogeneous: AMD only, 4 GiB/vCPU only. The bare "D"
# family conflates three things we do not want — Intel parts (Ds/Dls), and the
# low-memory 2 GiB/vCPU "l" series (Dals/Dls) — none of which carry a vendor or
# memory-ratio label to filter on, so the series allow-list is the only handle.
# All listed series are premium-storage capable, which in Azure costs the same
# per hour as the (now v4-only) non-premium variants, so there is no reason to
# admit non-premium SKUs and force premium-PVC pods onto per-pod nodeAffinity.
# Spanning v5-v7 keeps a wide capacity pool; Karpenter prefers the cheapest
# (v6/v7) and falls back to v5 only on shortage. sku-cpu + the CPU limit bound
# node size and total cost.
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
            # AMD general-purpose, 4 GiB/vCPU, premium-capable D-series only.
            # Excludes Intel (Ds/Dls), low-memory (Dals/Dls), and ARM (Dpls).
            # Smallest member (D2as) gives an implicit 2 vCPU floor, matching the
            # explicit eks_node_cpu_min on AWS; no Gt requirement needed here.
            { key = "karpenter.azure.com/sku-series", operator = "In", values = ["Das_v5", "Das_v6", "Das_v7"] },
            { key = "karpenter.azure.com/sku-cpu", operator = "Lt", values = [tostring(local.aks_node_cpu_max + 1)] },
            # Belt-and-suspenders: the series above are all premium-capable, but
            # keep this so a stray non-premium series can never admit a node that
            # fails to attach a Premium SSD / Premium SSD v2 disk for stateful PVCs.
            { key = "karpenter.azure.com/sku-storage-premium-capable", operator = "In", values = ["true"] },
          ]
          nodeClassRef = {
            group = "karpenter.azure.com"
            kind  = "AKSNodeClass"
            name  = "default"
          }
          expireAfter = "720h"
        }
      }
      # Total vCPU ceiling for this NodePool (size-profiles.tf).
      limits = {
        cpu = local.aks_node_cpu_limit
      }
      disruption = {
        # Bin-pack underutilized nodes, not just empty ones, to keep node count
        # tracking actual demand.
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        # Hold a drained node 15m so a brief dip doesn't tear it down right as
        # load returns (avoids scale-up lag).
        consolidateAfter = "15m"
      }
    }
  })

  depends_on = [kubectl_manifest.karpenter_node_class]
}
