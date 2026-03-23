###
# SeaweedFS (S3-compatible object storage) for local deployments
###

locals {
  seaweedfs_namespace = "seaweedfs"

  seaweedfs_s3_access_key = "gdcn"

  seaweedfs_buckets = [
    var.seaweedfs_bucket_exports,
    var.seaweedfs_bucket_datasource_fs,
    var.seaweedfs_bucket_quiver_cache,
  ]
}

resource "kubernetes_namespace_v1" "seaweedfs" {
  metadata {
    name = local.seaweedfs_namespace
    labels = var.enable_istio_injection ? {
      "istio-injection" = "enabled"
    } : null
  }
}

resource "random_password" "seaweedfs_s3_secret_key" {
  length  = 40
  special = false
}

resource "kubernetes_secret_v1" "seaweedfs_s3_credentials" {
  metadata {
    name      = "seaweedfs-s3-credentials"
    namespace = kubernetes_namespace_v1.seaweedfs.metadata[0].name
  }

  type = "Opaque"
  data = {
    secretKey = random_password.seaweedfs_s3_secret_key.result
  }

  lifecycle {
    # After first apply, don't rotate credentials unless explicitly tainted/replaced.
    ignore_changes = [data]
  }
}

resource "helm_release" "seaweedfs" {
  name       = var.seaweedfs_release_name
  repository = "https://seaweedfs.github.io/seaweedfs/helm"
  chart      = "seaweedfs"
  version    = var.helm_seaweedfs_version
  namespace  = kubernetes_namespace_v1.seaweedfs.metadata[0].name

  create_namespace = false
  wait             = true
  wait_for_jobs    = true
  timeout          = 600

  values = [
    yamlencode({
      # Single pod running master + volume + filer + S3 gateway.
      allInOne = {
        enabled  = true
        replicas = 1

        # Default -volume.max is 8 which is quickly exhausted when
        # multiple buckets/collections are in use.  Raise it so
        # SeaweedFS can allocate volumes for every collection.
        #
        # Raise garbageThreshold (default 0.3) so the continuous vacuum
        # loop only compacts volumes with significant garbage.  The
        # quiver-cache health-check writes/deletes a small file every
        # ~60 s, creating tombstones that otherwise trigger compaction
        # on every vacuum pass across all volumes.
        extraArgs = ["-volume.max=24", "-master.garbageThreshold=0.5"]

        s3 = {
          enabled    = true
          port       = 8333
          enableAuth = true
          # createBuckets is NOT used here — the chart's post-install-bucket-hook
          # template (v4.15.0) has a YAML indentation bug that produces invalid
          # output.  Buckets are created by the kubernetes_job below instead.
        }

        data = {
          type         = "persistentVolumeClaim"
          size         = "10Gi"
          storageClass = var.seaweedfs_storage_class
        }

        resources = {
          requests = {
            cpu    = "100m"
            memory = "256Mi"
          }
          limits = {
            cpu    = "500m"
            memory = "512Mi"
          }
        }
      }

      # Disable standalone components — allInOne already provides them.
      master = { enabled = false }
      volume = { enabled = false }
      filer  = { enabled = false }

      # Credentials are read from the top-level s3 block regardless of mode.
      # enableAuth must be set here (not only in allInOne.s3) so the chart's
      # s3-secret template creates the seaweedfs-s3-secret Secret.
      s3 = {
        enableAuth = true
        credentials = {
          admin = {
            accessKey = local.seaweedfs_s3_access_key
            secretKey = kubernetes_secret_v1.seaweedfs_s3_credentials.data["secretKey"]
          }
        }
      }
    })
  ]

  depends_on = [
    kubernetes_secret_v1.seaweedfs_s3_credentials,
  ]
}

# --------------------------------------------------------------------------
# Bucket creation job — works around the broken createBuckets hook in chart
# v4.15.0.  Runs `weed shell` commands to create each bucket if it does not
# already exist.
# --------------------------------------------------------------------------

resource "kubernetes_job_v1" "seaweedfs_create_buckets" {
  metadata {
    name      = "seaweedfs-create-buckets"
    namespace = kubernetes_namespace_v1.seaweedfs.metadata[0].name
  }

  spec {
    backoff_limit = 4

    template {
      metadata {}

      spec {
        restart_policy = "OnFailure"

        container {
          name  = "create-buckets"
          image = "${var.registry_dockerio}/chrislusf/seaweedfs:${split(".", var.helm_seaweedfs_version)[0]}.${split(".", var.helm_seaweedfs_version)[1]}"

          env {
            name  = "WEED_CLUSTER_DEFAULT"
            value = "sw"
          }
          env {
            name  = "WEED_CLUSTER_SW_MASTER"
            value = "${var.seaweedfs_release_name}-all-in-one.${local.seaweedfs_namespace}:9333"
          }
          env {
            name  = "WEED_CLUSTER_SW_FILER"
            value = "${var.seaweedfs_release_name}-all-in-one.${local.seaweedfs_namespace}:8888"
          }

          command = ["/bin/sh", "-ec", join("\n", concat(
            [
              # Wait for the filer to become ready.
              "max=60; i=1",
              "echo 'Waiting for SeaweedFS filer...'",
              "while [ $i -le $max ]; do",
              "  if wget -q --spider http://$WEED_CLUSTER_SW_FILER/ 2>/dev/null; then break; fi",
              "  echo \"Attempt $i: not ready, retrying in 5s...\"",
              "  sleep 5; i=$((i+1))",
              "done",
              "if [ $i -gt $max ]; then echo 'SeaweedFS filer did not become ready in time'; exit 1; fi",
            ],
            # Create each bucket if it doesn't already exist.
            flatten([for b in local.seaweedfs_buckets : [
              "bucket_list=$(/bin/echo 's3.bucket.list' | /usr/bin/weed shell)",
              "if echo \"$bucket_list\" | awk '{print $1}' | grep -Fxq '${b}'; then",
              "  echo \"Bucket '${b}' already exists\"",
              "else",
              "  echo \"Creating bucket '${b}'...\"",
              "  /bin/echo 's3.bucket.create --name ${b}' | /usr/bin/weed shell",
              "fi",
            ]]),
          ))]
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "10m"
    update = "10m"
  }

  depends_on = [helm_release.seaweedfs]
}
