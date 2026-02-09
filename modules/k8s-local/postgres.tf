###
# CloudNativePG operator + PostgreSQL cluster
###

locals {
  cnpg_namespace     = "cnpg-system"
  postgres_namespace = "postgres"
}

resource "kubernetes_namespace" "postgres" {
  metadata {
    name = local.postgres_namespace
  }
}

resource "kubernetes_namespace" "cnpg" {
  metadata {
    name = local.cnpg_namespace
  }
}

resource "helm_release" "cnpg" {
  name             = "cnpg"
  repository       = "https://cloudnative-pg.github.io/charts"
  chart            = "cloudnative-pg"
  namespace        = kubernetes_namespace.cnpg.metadata[0].name
  create_namespace = false
  version          = var.helm_cnpg_version
  wait             = true
  wait_for_jobs    = true
  timeout          = 600

  depends_on = [
    kubernetes_namespace.cnpg,
  ]
}

resource "kubernetes_secret" "postgres_superuser" {
  metadata {
    name      = "postgres-superuser"
    namespace = kubernetes_namespace.postgres.metadata[0].name
  }

  type = "kubernetes.io/basic-auth"
  data = {
    username = var.db_username
    password = var.db_password
  }

  depends_on = [
    kubernetes_namespace.postgres,
  ]
}

resource "kubectl_manifest" "postgres_cluster" {
  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"
    metadata = {
      name      = "postgres"
      namespace = kubernetes_namespace.postgres.metadata[0].name
    }
    spec = {
      instances             = 1
      imageName             = var.postgres_image
      primaryUpdateStrategy = "unsupervised"
      enableSuperuserAccess = true
      superuserSecret = {
        name = kubernetes_secret.postgres_superuser.metadata[0].name
      }

      storage = {
        size         = "2Gi"
        storageClass = "local-path"
      }

      bootstrap = {
        initdb = {
          database = "postgres"
          owner    = var.db_username
          secret = {
            name = kubernetes_secret.postgres_superuser.metadata[0].name
          }
        }
      }

      resources = {
        requests = {
          cpu    = "200m"
          memory = "256Mi"
        }
      }

      postgresql = {
        pg_hba = [
          "host all all 0.0.0.0/0 scram-sha-256",
        ]
      }
    }
  })

  depends_on = [
    helm_release.cnpg,
    kubernetes_secret.postgres_superuser,
  ]
}

data "external" "wait_postgres_ready" {
  program = [
    "bash",
    "-c",
    <<-EOT
      set -euo pipefail

      if ! command -v kubectl >/dev/null 2>&1; then
        echo "kubectl is required to wait for the local PostgreSQL cluster readiness." >&2
        exit 1
      fi

      kubectl -n "${kubernetes_namespace.postgres.metadata[0].name}" wait --for=condition=Ready --timeout=600s cluster/postgres >/dev/null
      printf '{"ready":"true"}'
    EOT
  ]

  depends_on = [
    kubectl_manifest.postgres_cluster,
  ]
}

