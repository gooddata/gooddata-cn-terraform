###
# Default StorageClass on GKE (PD CSI)
###

resource "kubernetes_storage_class_v1" "standard_csi_gp" {
  metadata {
    name = "standard-csi-gp"
  }

  storage_provisioner = "pd.csi.storage.gke.io"
  reclaim_policy      = "Delete"
  volume_binding_mode = "WaitForFirstConsumer"

  parameters = {
    type = "pd-balanced"
  }
}
