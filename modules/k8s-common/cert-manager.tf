###
# Deploy cert-manager to Kubernetes when tls_mode is cert-manager
###

resource "kubernetes_namespace" "cert-manager" {
  count = local.use_cert_manager ? 1 : 0

  metadata {
    name = "cert-manager"
  }
}

resource "helm_release" "cert-manager" {
  count = local.use_cert_manager ? 1 : 0

  name          = "cert-manager"
  namespace     = kubernetes_namespace.cert-manager[0].metadata[0].name
  chart         = "cert-manager"
  repository    = "https://charts.jetstack.io"
  version       = var.helm_cert_manager_version
  wait          = true
  wait_for_jobs = true
  timeout       = 1800
  values = [<<EOF
image:
  repository: ${var.registry_quayio}/jetstack/cert-manager-controller

webhook:
  image:
    repository: ${var.registry_quayio}/jetstack/cert-manager-webhook

cainjector:
  image:
    repository: ${var.registry_quayio}/jetstack/cert-manager-cainjector

acmesolver:
  image:
    repository: ${var.registry_quayio}/jetstack/cert-manager-acmesolver

startupapicheck:
  image:
    repository: ${var.registry_quayio}/jetstack/cert-manager-startupapicheck

installCRDs: true
  EOF
  ]

  depends_on = [kubernetes_namespace.cert-manager]
}

resource "kubectl_manifest" "letsencrypt_cluster_issuer" {
  count = local.use_cert_manager ? 1 : 0

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
                ingressClassName: ${local.resolved_ingress_class_name}
                %{~if local.resolved_ingress_class_name == "nginx"~}
                ingressTemplate:
                  metadata:
                    annotations:
                      nginx.ingress.kubernetes.io/enable-validate-ingress: "false"
                %{~endif~}
  YAML

  depends_on = [helm_release.cert-manager]
}
