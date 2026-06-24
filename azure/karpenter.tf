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

  depends_on = [azurerm_kubernetes_cluster.main]
}

# General-purpose NodePool: on-demand only, constrained to the VM sizes from
# the active size profile (size-profiles.tf). Karpenter picks the cheapest VM
# size that fits the pending pods, replacing the least-waste cluster
# autoscaler.
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
            { key = "node.kubernetes.io/instance-type", operator = "In", values = local.aks_node_vm_sizes },
          ]
          nodeClassRef = {
            group = "karpenter.azure.com"
            kind  = "AKSNodeClass"
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
