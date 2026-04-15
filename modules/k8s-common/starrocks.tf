###
# Deploy StarRocks in shared-data mode (FE + CN, S3 storage)
###

resource "kubernetes_namespace_v1" "starrocks" {
  count = var.enable_ai_lake ? 1 : 0

  metadata {
    name = local.starrocks_namespace
    labels = local.use_istio_gateway ? {
      "istio-injection" = "enabled"
    } : null
  }
}

resource "random_password" "starrocks_root" {
  count = var.enable_ai_lake ? 1 : 0

  length           = 24
  special          = true
  override_special = "_%@-"
}

resource "kubernetes_secret_v1" "starrocks_root_password" {
  count = var.enable_ai_lake ? 1 : 0

  metadata {
    name      = "starrocks-root-password"
    namespace = kubernetes_namespace_v1.starrocks[0].metadata[0].name
  }

  data = {
    password = random_password.starrocks_root[0].result
  }

  lifecycle {
    ignore_changes = [data]
  }
}

resource "random_password" "starrocks_catalog_user" {
  count = var.enable_ai_lake ? 1 : 0

  length           = 24
  special          = true
  override_special = "_%@-"
}

resource "kubernetes_secret_v1" "starrocks_catalog_user_password" {
  count = var.enable_ai_lake ? 1 : 0

  metadata {
    name      = "starrocks-catalog-user-password"
    namespace = kubernetes_namespace_v1.starrocks[0].metadata[0].name
  }

  data = {
    password = random_password.starrocks_catalog_user[0].result
  }

  lifecycle {
    ignore_changes = [data]
  }
}

resource "kubernetes_secret_v1" "starrocks_s3_tables_credentials" {
  count = var.enable_ai_lake && var.cloud == "aws" ? 1 : 0

  metadata {
    name      = "starrocks-s3-tables-credentials"
    namespace = kubernetes_namespace_v1.starrocks[0].metadata[0].name
  }

  data = {
    access_key_id     = var.starrocks_s3_tables_access_key_id
    secret_access_key = var.starrocks_s3_tables_secret_access_key
  }

  lifecycle {
    ignore_changes = [data]
  }
}

locals {
  starrocks_fe_heap_mb = {
    dev        = 4096
    prod-small = 4096
  }
}

resource "helm_release" "starrocks" {
  count = var.enable_ai_lake ? 1 : 0

  name       = "kube-starrocks"
  repository = "https://starrocks.github.io/starrocks-kubernetes-operator"
  chart      = "kube-starrocks"
  version    = var.helm_starrocks_version
  namespace  = kubernetes_namespace_v1.starrocks[0].metadata[0].name

  values = compact([
    templatefile("${path.module}/templates/starrocks-base.yaml.tftpl", {
      registry_dockerio         = var.registry_dockerio
      starrocks_service_account = local.starrocks_service_account_name
      root_password_secret      = kubernetes_secret_v1.starrocks_root_password[0].metadata[0].name
      enable_observability      = var.enable_observability
      starrocks_fe_image_tag    = var.starrocks_fe_image_tag
      starrocks_cn_image_tag    = var.starrocks_cn_image_tag
      fe_java_heap_mb           = local.starrocks_fe_heap_mb[var.size_profile]
    }),
    var.cloud == "aws" ? templatefile("${path.module}/templates/starrocks-aws.yaml.tftpl", {
      starrocks_irsa_role_arn      = var.starrocks_irsa_role_arn
      root_password_secret         = kubernetes_secret_v1.starrocks_root_password[0].metadata[0].name
      catalog_user_password_secret = kubernetes_secret_v1.starrocks_catalog_user_password[0].metadata[0].name
      s3_tables_credentials_secret = kubernetes_secret_v1.starrocks_s3_tables_credentials[0].metadata[0].name
      aws_region                   = var.aws_region
      aws_account_id               = var.aws_account_id
      starrocks_s3_bucket_id       = var.starrocks_s3_bucket_id
      s3_tables_bucket_name        = var.starrocks_s3_tables_bucket_name
      fe_java_heap_mb              = local.starrocks_fe_heap_mb[var.size_profile]
    }) : null,
    templatefile("${path.module}/templates/starrocks-size-${var.size_profile}.yaml.tftpl", {}),
  ])

  wait          = true
  wait_for_jobs = true
  timeout       = 1800

  depends_on = [
    helm_release.kube_prometheus_stack,
  ]
}

# The StarRocks Helm chart does not include PodDisruptionBudget support,
# so PDBs for FE and CN are managed separately here.
resource "kubectl_manifest" "starrocks_pdb_fe" {
  count = var.enable_ai_lake ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "policy/v1"
    kind       = "PodDisruptionBudget"
    metadata = {
      name      = "starrocks-fe"
      namespace = kubernetes_namespace_v1.starrocks[0].metadata[0].name
    }
    spec = {
      maxUnavailable = 1
      selector = {
        matchLabels = {
          "app.starrocks.ownerreference/name" = "kube-starrocks-fe"
        }
      }
    }
  })

  depends_on = [
    helm_release.starrocks,
  ]
}

resource "kubectl_manifest" "starrocks_pdb_cn" {
  count = var.enable_ai_lake ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "policy/v1"
    kind       = "PodDisruptionBudget"
    metadata = {
      name      = "starrocks-cn"
      namespace = kubernetes_namespace_v1.starrocks[0].metadata[0].name
    }
    spec = {
      maxUnavailable = 1
      selector = {
        matchLabels = {
          "app.starrocks.ownerreference/name" = "kube-starrocks-cn"
        }
      }
    }
  })

  depends_on = [
    helm_release.starrocks,
  ]
}

resource "kubectl_manifest" "peerauth_starrocks_strict" {
  count = var.enable_ai_lake && local.use_istio_gateway ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "security.istio.io/v1beta1"
    kind       = "PeerAuthentication"
    metadata   = { name = "default", namespace = kubernetes_namespace_v1.starrocks[0].metadata[0].name }
    spec       = { mtls = { mode = "STRICT" } }
  })

  depends_on = [
    kubernetes_namespace_v1.starrocks,
    helm_release.istiod,
  ]
}

output "starrocks_catalog_username" {
  value = var.enable_ai_lake ? "gooddata" : null
}

output "starrocks_catalog_user_password" {
  value     = var.enable_ai_lake ? random_password.starrocks_catalog_user[0].result : null
  sensitive = true
}
