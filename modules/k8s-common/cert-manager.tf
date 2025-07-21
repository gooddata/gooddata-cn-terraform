###
# Deploy cert-manager to Kubernetes
###

resource "kubernetes_namespace" "cert-manager" {
  metadata {
    name = "cert-manager"
  }
}

resource "helm_release" "cert-manager" {
  name       = "cert-manager"
  namespace  = kubernetes_namespace.cert-manager.metadata[0].name
  chart      = "cert-manager"
  repository = "https://charts.jetstack.io"
  version    = var.helm_cert_manager_version
  values = [<<EOF
image:
  repository: ${var.cache_quayio}/jetstack/cert-manager-controller

webhook:
  image:
    repository: ${var.cache_quayio}/jetstack/cert-manager-webhook

cainjector:
  image:
    repository: ${var.cache_quayio}/jetstack/cert-manager-cainjector

acmesolver:
  image:
    repository: ${var.cache_quayio}/jetstack/cert-manager-acmesolver

startupapicheck:
  image:
    repository: ${var.cache_quayio}/jetstack/cert-manager-startupapicheck

installCRDs: true
  EOF
  ]

  depends_on = [kubernetes_namespace.cert-manager]
}

resource "kubectl_manifest" "letsencrypt_cluster_issuer" {
  yaml_body = <<-YAML
    apiVersion: cert-manager.io/v1
    kind: ClusterIssuer
    metadata:
      name: letsencrypt
    spec:
      acme:
        email: ${var.letsencrypt_email}
        server: https://acme-v02.api.letsencrypt.org/directory
        privateKeySecretRef:
          name: letsencrypt-account-key
        solvers:
          - http01:
              ingress:
                class: nginx
                annotations:
                  nginx.ingress.kubernetes.io/enable-validate-ingress: "false"
  YAML

  depends_on = [helm_release.cert-manager]
}
