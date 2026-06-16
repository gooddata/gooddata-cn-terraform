###
# Kubernetes storage classes for AKS
###

# AKS ships StandardSSD_LRS as the cluster default ("default"/"managed-csi").
# Provision a Premium SSD (Premium_LRS) class and make it the cluster default
# so all GoodData.CN persistent volumes (Pulsar, etcd, redis-ha, Qdrant,
# observability) land on premium SSDs. WaitForFirstConsumer matches the AKS
# built-ins so zone-aware scheduling still works.
resource "kubernetes_storage_class_v1" "premium_ssd" {
  metadata {
    name = "premium-ssd"

    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "disk.csi.azure.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    skuname = "Premium_LRS"
  }

  depends_on = [azurerm_kubernetes_cluster.main]
}

# Demote the built-in StandardSSD default classes so exactly one default class
# (premium-ssd) remains. These StorageClasses are owned by AKS; only the
# is-default-class annotation is patched via server-side apply.
resource "kubernetes_annotations" "demote_standardssd_default" {
  for_each = toset(["default", "managed-csi"])

  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"

  metadata {
    name = each.value
  }

  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "false"
  }

  # The built-in classes carry this annotation from a different field manager;
  # take ownership of it rather than erroring on the conflict.
  force = true

  depends_on = [azurerm_kubernetes_cluster.main]
}
