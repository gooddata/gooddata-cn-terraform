###
# AKS StorageClasses for PVCs. Node OS disks are sized in aks.tf and karpenter.tf.
###

# Premium SSD v2: IOPS and throughput are provisioned independently of capacity.
# 3000 IOPS / 125 MBps is the free floor; the paid ceiling is 500 IOPS per GiB.
# Named explicitly by the prod size profiles, so it is not the cluster default.
# Needs zonal nodes and is unavailable in some regions.
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

# Premium SSD v1: IOPS follow capacity alone (128GiB=500, 512GiB=2300, 1TiB=5000).
# Non-default, for workloads needing snapshots or a region without v2.
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

# Make managed-csi the one cluster default and demote the built-in "default"
# class. Only catches PVCs that set no class, since our charts all set one.
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

  # AKS owns these classes and sets this annotation from another field manager;
  # take ownership rather than failing on the conflict.
  force = true

  depends_on = [
    azurerm_kubernetes_cluster.main,
    azurerm_role_assignment.aks_creator_cluster_admin,
  ]
}
