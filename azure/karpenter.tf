###
# Karpenter provisioning policy for Node Auto Provisioning (NAP).
#
# AKS runs the Karpenter controller and CRDs; we supply only the policy. The
# AKSNodeClass says how nodes are built, the NodePool what may be provisioned.
# The cluster sets default_node_pools=None, so these are the only NodePools.
###

# Node OS disk holds every emptyDir, including Quiver's flight catalog, which is
# I/O heavy. Premium SSD v1 IOPS scale only with capacity, so 1TiB buys P30's
# 5000 IOPS / 200 MBps; 100GB would cap the whole node at P10's 500 IOPS.
resource "kubectl_manifest" "karpenter_node_class" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.azure.com/v1beta1"
    kind       = "AKSNodeClass"
    metadata = {
      name = "default"
    }
    spec = {
      imageFamily  = "Ubuntu2204"
      osDiskSizeGB = 1024
    }
  })

  depends_on = [
    azurerm_kubernetes_cluster.main,
    azurerm_role_assignment.aks_creator_cluster_admin,
  ]
}

# General-purpose NodePool: on-demand AMD D-series, 4 GiB/vCPU, v6/v7 only.
# The series allow-list is the only way to exclude Intel (Ds/Dls) and the
# low-memory "l" series (Dals/Dls); neither carries a label to filter on.
# sku-cpu and the NodePool CPU limit bound per-node size and total fleet cost.
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
            # Smallest member (D2as) gives an implicit 2 vCPU floor, so no Gt
            # requirement is needed here.
            { key = "karpenter.azure.com/sku-series", operator = "In", values = ["Das_v6", "Das_v7"] },
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
