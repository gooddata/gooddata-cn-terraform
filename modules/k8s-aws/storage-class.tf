###
# Configure Kubernetes storage class
###

# encrypted = "true" on both classes, so PVC data is encrypted at rest even if
# the account has no default-encryption setting. kmsKeyId is deliberately unset,
# which means each volume uses whichever key the account has configured as its
# EBS default — aws/managed unless someone has pointed it at a CMK.

resource "kubernetes_storage_class_v1" "gp3_perf" {
  metadata {
    name = "gp3-perf"
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  # Fast class for latency-sensitive PVCs. 3000 IOPS is the ceiling valid at any
  # size; above it EBS caps gp3 provisioned IOPS at 500/GiB. Throughput is the
  # real gain here: 300 MBps against the 125 the default class gets free.
  parameters = {
    type       = "gp3"
    iops       = "3000"
    throughput = "300"
    encrypted  = "true"
  }
}

# etcd class for prod-large and prod-xl. Quiver confirms every write through etcd fsync:
# at ~10,000 puts/s (load test 2026-10-22) the 3000-IOPS gp3-perf etcd volumes were
# 78-93 % busy. 10000 IOPS needs a volume of at least 20 GiB (gp3 caps IOPS at 500/GiB);
# the chart's etcd PVCs are 30 GiB.
resource "kubernetes_storage_class_v1" "gp3_etcd" {
  metadata {
    name = "gp3-etcd"
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type       = "gp3"
    iops       = "10000"
    throughput = "500"
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
