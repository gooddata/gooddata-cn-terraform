###
# MinIO (S3-compatible object storage) for local deployments
###

locals {
  minio_namespace = "minio"
}

resource "kubernetes_namespace" "minio" {
  metadata {
    name = local.minio_namespace
  }
}

resource "random_password" "minio_root_password" {
  length  = 32
  special = false
}

resource "random_password" "minio_gdcn_secret_key" {
  length  = 40
  special = false
}

resource "kubernetes_secret" "minio_root" {
  metadata {
    name      = "minio-root"
    namespace = kubernetes_namespace.minio.metadata[0].name
  }

  type = "Opaque"
  data = {
    rootUser     = "minio-root"
    rootPassword = random_password.minio_root_password.result
  }

  lifecycle {
    # After first apply, don't rotate credentials unless explicitly tainted/replaced.
    ignore_changes = [data]
  }
}

resource "kubernetes_secret" "minio_gdcn_user" {
  metadata {
    name      = "minio-gdcn-user"
    namespace = kubernetes_namespace.minio.metadata[0].name
  }

  type = "Opaque"
  data = {
    secretKey = random_password.minio_gdcn_secret_key.result
  }

  lifecycle {
    # After first apply, don't rotate credentials unless explicitly tainted/replaced.
    ignore_changes = [data]
  }
}

resource "helm_release" "minio" {
  name       = var.minio_release_name
  repository = "https://charts.min.io/"
  chart      = "minio"
  version    = var.helm_minio_version
  namespace  = kubernetes_namespace.minio.metadata[0].name

  create_namespace = false
  wait             = true
  wait_for_jobs    = true
  timeout          = 600

  values = [
    yamlencode({
      mode = "standalone"

      # Keep local footprint small.
      replicas = 1
      resources = {
        requests = {
          memory = "256Mi"
        }
      }

      existingSecret = kubernetes_secret.minio_root.metadata[0].name

      persistence = {
        enabled      = true
        accessMode   = "ReadWriteOnce"
        size         = "10Gi"
        storageClass = var.minio_storage_class
      }

      service = {
        type = "ClusterIP"
        port = "9000"
      }

      consoleService = {
        type = "ClusterIP"
        port = "9001"
      }

      # Buckets used by GoodData.CN.
      buckets = [
        { name = var.minio_bucket_exports, policy = "none", purge = false },
        { name = var.minio_bucket_datasource_fs, policy = "none", purge = false },
        { name = var.minio_bucket_quiver_cache, policy = "none", purge = false },
      ]

      # Minimal policy for GoodData.CN to work with the three buckets.
      policies = [
        {
          name = "gdcn-rw"
          statements = [
            {
              resources = [
                "arn:aws:s3:::${var.minio_bucket_exports}/*",
                "arn:aws:s3:::${var.minio_bucket_datasource_fs}/*",
                "arn:aws:s3:::${var.minio_bucket_quiver_cache}/*",
              ]
              actions = [
                "s3:AbortMultipartUpload",
                "s3:GetObject",
                "s3:DeleteObject",
                "s3:PutObject",
                "s3:ListMultipartUploadParts",
              ]
            },
            {
              resources = [
                "arn:aws:s3:::${var.minio_bucket_exports}",
                "arn:aws:s3:::${var.minio_bucket_datasource_fs}",
                "arn:aws:s3:::${var.minio_bucket_quiver_cache}",
              ]
              actions = [
                "s3:CreateBucket",
                "s3:DeleteBucket",
                "s3:GetBucketLocation",
                "s3:ListBucket",
                "s3:ListBucketMultipartUploads",
              ]
            },
          ]
        }
      ]

      # Dedicated user for apps (avoid using MinIO root credentials).
      users = [
        {
          accessKey         = "gdcn"
          existingSecret    = kubernetes_secret.minio_gdcn_user.metadata[0].name
          existingSecretKey = "secretKey"
          policy            = "gdcn-rw"
        }
      ]
    })
  ]

  depends_on = [
    kubernetes_secret.minio_root,
    kubernetes_secret.minio_gdcn_user,
  ]
}

