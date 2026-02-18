###
# Deploy cert-manager to Kubernetes when tls_mode uses cert-manager
###

locals {
  cert_manager_http01_ingress_class = local.use_istio_gateway ? "istio" : local.resolved_ingress_class_name
  cert_manager_http01_ingress_annotations = local.cert_manager_http01_ingress_class == "nginx" ? {
    "nginx.ingress.kubernetes.io/enable-validate-ingress" = "false"
  } : {}
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
  chart         = "cert-manager"
  repository    = "https://charts.jetstack.io"
  version       = var.helm_cert_manager_version
  wait          = true
  wait_for_jobs = true
  timeout       = 1800
  values = [yamlencode({
    installCRDs = true
    serviceAccount = {
      create = true
      name   = "cert-manager"
    }
    image           = { repository = "${var.registry_quayio}/jetstack/cert-manager-controller" }
    webhook         = { image = { repository = "${var.registry_quayio}/jetstack/cert-manager-webhook" } }
    cainjector      = { image = { repository = "${var.registry_quayio}/jetstack/cert-manager-cainjector" } }
    acmesolver      = { image = { repository = "${var.registry_quayio}/jetstack/cert-manager-acmesolver" } }
    startupapicheck = { image = { repository = "${var.registry_quayio}/jetstack/cert-manager-startupapicheck" } }
  })]

  depends_on = [kubernetes_namespace_v1.cert-manager]
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
            ingress = merge(
              { ingressClassName = local.cert_manager_http01_ingress_class },
              local.cert_manager_http01_ingress_class == "nginx" ? {
                ingressTemplate = {
                  metadata = {
                    annotations = { "nginx.ingress.kubernetes.io/enable-validate-ingress" = "false" }
                  }
                }
              } : {}
            )
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
