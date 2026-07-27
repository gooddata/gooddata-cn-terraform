###
# Configure Kubernetes storage class
###

# encrypted = "true" on both classes, so PVC data is encrypted at rest without
# relying on the account default. Unset kmsKeyId uses the AWS-managed EBS key.

resource "kubernetes_storage_class_v1" "gp3_perf" {
  metadata {
    name = "gp3-perf"
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type       = "gp3"
    iops       = "5000"
    throughput = "300"
    encrypted  = "true"
  }
}

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"

    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }
}
