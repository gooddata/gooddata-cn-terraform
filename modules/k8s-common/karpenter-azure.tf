###
# Karpenter NodePool CRD for Azure NAP
# This is deployed after NAP is enabled on the AKS cluster
###

# Deploy NodePool CRD for Azure NAP
resource "kubectl_manifest" "azure_karpenter_node_pool" {
  count = var.cloud == "azure" ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1beta1"
    kind       = "NodePool"
    metadata = {
      name = "default"
    }
    spec = {
      disruption = {
        consolidationPolicy = "WhenUnderutilized"
        expireAfter         = "Never"
      }
      template = {
        spec = {
          nodeClassRef = {
            name = "default"
          }
          requirements = [
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64"]
            },
            {
              key      = "kubernetes.io/os"
              operator = "In"
              values   = ["linux"]
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = ["on-demand"]
            },
            {
              key      = "karpenter.azure.com/sku-family"
              operator = "In"
              values   = var.karpenter_sku_families
            }
          ]
        }
      }
    }
  })
}
