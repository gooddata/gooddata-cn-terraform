###
# Kubernetes storage classes for AKS
###

# Premium SSD v2 (PremiumV2_LRS), referenced explicitly by the prod size
# profiles (see size-profiles.tf). NOT the cluster default — every PVC sets its
# class by name per profile. v2 lets IOPS/throughput scale independently of disk
# size; 3000 IOPS / 125 MBps is the free baseline. Requires zonal nodes (see
# aks.tf zones) and isn't available in every region. WaitForFirstConsumer aligns
# the disk to the pod's zone.
resource "kubernetes_storage_class_v1" "premium_ssd_v2" {
  metadata {
    name = "premium-ssd-v2"

    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "false"
    }
  }

  storage_provisioner    = "disk.csi.azure.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    skuname           = "PremiumV2_LRS"
    DiskIOPSReadWrite = "3000"
    DiskMBpsReadWrite = "125"
  }

  depends_on = [
    azurerm_kubernetes_cluster.main,
    azurerm_role_assignment.aks_creator_cluster_admin,
  ]
}

# Premium SSD v1 (Premium_LRS) kept as a non-default class so workloads can pin
# to it explicitly (e.g. where v2 is unavailable or snapshots are needed).
resource "kubernetes_storage_class_v1" "premium_ssd" {
  metadata {
    name = "premium-ssd"

    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "false"
    }
  }

  storage_provisioner    = "disk.csi.azure.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    skuname = "Premium_LRS"
  }

  depends_on = [
    azurerm_kubernetes_cluster.main,
    azurerm_role_assignment.aks_creator_cluster_admin,
  ]
}

# Cluster default = the built-in StandardSSD class "managed-csi" (standard tier).
# GoodData.CN / Pulsar / observability PVCs all set their class explicitly per
# size_profile, so this default only catches anything otherwise unset. The other
# built-in "default" class (also StandardSSD) is demoted so exactly one default
# remains. These classes are owned by AKS; only the is-default-class annotation
# is patched via server-side apply.
resource "kubernetes_annotations" "default_storage_class" {
  for_each = {
    "default"     = "false"
    "managed-csi" = "true"
  }

  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"

  metadata {
    name = each.key
  }

  annotations = {
    "storageclass.kubernetes.io/is-default-class" = each.value
  }

  # The built-in classes carry this annotation from a different field manager;
  # take ownership of it rather than erroring on the conflict.
  force = true

  depends_on = [
    azurerm_kubernetes_cluster.main,
    azurerm_role_assignment.aks_creator_cluster_admin,
  ]
}
