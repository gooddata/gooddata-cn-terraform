###
# Deploy cert-manager to Kubernetes when tls_mode uses cert-manager
###

locals {
  cert_manager_http01_ingress_class = local.use_istio_gateway ? "istio" : local.resolved_ingress_class_name
}

resource "kubernetes_namespace_v1" "cert-manager" {
  count = local.use_cert_manager ? 1 : 0

  metadata {
    name = "cert-manager"
  }
}

resource "helm_release" "cert-manager" {
  count = local.use_cert_manager ? 1 : 0

  name          = "cert-manager"
  namespace     = kubernetes_namespace_v1.cert-manager[0].metadata[0].name
  chart         = "cert-manager-chart"
  repository    = "oci://${local.dhi_registry}"
  version       = var.helm_cert_manager_version
  wait          = true
  wait_for_jobs = true
  timeout       = 1800

  repository_username = var.dhi_username
  repository_password = var.dhi_access_token

  values = [yamlencode(merge(
    {
      installCRDs = true
      global      = { imagePullSecrets = [{ name = local.dhi_pull_secret_name }] }
      serviceAccount = {
        create = true
        name   = "cert-manager"
      }
    },
    var.enable_observability ? {
      prometheus = {
        servicemonitor = { enabled = true }
      }
    } : {}
  ))]

  depends_on = [
    kubernetes_namespace_v1.cert-manager,
    module.dhi_pull,
    helm_release.kube_prometheus_stack,
  ]
}

resource "kubectl_manifest" "letsencrypt_cluster_issuer" {
  count = var.tls_mode == "letsencrypt" ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata   = { name = "letsencrypt" }
    spec = {
      acme = {
        email               = var.letsencrypt_email
        server              = "https://acme-v02.api.letsencrypt.org/directory"
        privateKeySecretRef = { name = "letsencrypt-account-key" }
        solvers = [{
          http01 = {
            ingress = {
              ingressClassName = local.cert_manager_http01_ingress_class
              podTemplate = {
                spec = { imagePullSecrets = [{ name = local.dhi_pull_secret_name }] }
              }
            }
          }
        }]
      }
    }
  })

  depends_on = [helm_release.cert-manager]
}

resource "kubectl_manifest" "selfsigned_cluster_issuer" {
  count = var.tls_mode == "selfsigned" ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata   = { name = "selfsigned" }
    spec       = { selfSigned = {} }
  })

  depends_on = [helm_release.cert-manager]
}
