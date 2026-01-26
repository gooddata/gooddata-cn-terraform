###
# Install Istio (optional)
#
# When enable_istio = true, we install Istio and expose the
# ingress gateway as NodePort so an external load balancer can forward to it.
###

locals {
  istio_enabled       = var.enable_istio
  istio_chart_repo    = "https://istio-release.storage.googleapis.com/charts"
  istio_system_ns     = "istio-system"
  istio_ingress_ns    = "istio-ingress"
  istio_ingress_name  = "istio-ingress"
  istio_ingress_label = "ingressgateway"
}

resource "kubernetes_namespace" "istio_system" {
  count = local.istio_enabled ? 1 : 0

  metadata {
    name = local.istio_system_ns
  }
}

resource "helm_release" "istio_base" {
  count = local.istio_enabled ? 1 : 0

  name       = "istio-base"
  repository = local.istio_chart_repo
  chart      = "base"
  version    = var.helm_istio_version
  namespace  = kubernetes_namespace.istio_system[0].metadata[0].name

  wait          = true
  wait_for_jobs = true
  timeout       = 1800
}

resource "helm_release" "istiod" {
  count = local.istio_enabled ? 1 : 0

  name       = "istiod"
  repository = local.istio_chart_repo
  chart      = "istiod"
  version    = var.helm_istio_version
  namespace  = kubernetes_namespace.istio_system[0].metadata[0].name

  values = [yamlencode({
    meshConfig = {
      accessLogFile = "/dev/stdout"
    }
  })]

  wait          = true
  wait_for_jobs = true
  timeout       = 1800

  depends_on = [
    helm_release.istio_base,
  ]
}

resource "helm_release" "istio_ingress_gateway" {
  count = local.istio_enabled ? 1 : 0

  name             = local.istio_ingress_name
  repository       = local.istio_chart_repo
  chart            = "gateway"
  version          = var.helm_istio_version
  namespace        = local.istio_ingress_ns
  create_namespace = true

  values = [yamlencode({
    labels = {
      istio = local.istio_ingress_label
    }
    service = {
      type = "NodePort"
      ports = [
        {
          name       = "status-port"
          port       = 15021
          targetPort = 15021
          nodePort   = 32021
          protocol   = "TCP"
        },
        {
          name       = "http2"
          port       = 80
          targetPort = 80
          nodePort   = 32080
          protocol   = "TCP"
        },
        {
          name       = "https"
          port       = 443
          targetPort = 443
          nodePort   = 32443
          protocol   = "TCP"
        }
      ]
    }
  })]

  wait          = true
  wait_for_jobs = true
  timeout       = 1800

  depends_on = [
    helm_release.istiod,
  ]
}

###
# Backend TLS for ALB → Istio ingress gateway
#
# ACM terminates user-facing TLS on the ALB. For the ALB→Istio hop we still
# use HTTPS (end-to-end encryption) with a Terraform-managed self-signed cert.
#
# NOTE: This cert is only used internally between the ALB and Istio.
###

resource "tls_private_key" "alb_to_istio" {
  count     = local.istio_enabled ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "alb_to_istio" {
  count           = local.istio_enabled ? 1 : 0
  private_key_pem = tls_private_key.alb_to_istio[0].private_key_pem

  subject {
    common_name  = "alb-to-istio"
    organization = "gooddata-cn-terraform"
  }

  # ALB does not validate backend certs by default, but we include these SANs
  # for clarity and future compatibility.
  dns_names = distinct(compact(concat(
    [trimspace(var.auth_hostname)],
    [for org in var.gdcn_orgs : trimspace(org.hostname)]
  )))

  validity_period_hours = 24 * 365
  allowed_uses = [
    "digital_signature",
    "key_encipherment",
    "server_auth",
  ]
}

resource "kubernetes_secret" "istio_backend_tls_ingress" {
  count = local.istio_enabled ? 1 : 0

  metadata {
    name      = local.istio_backend_tls_secret_name
    namespace = local.istio_ingress_ns
  }

  type = "kubernetes.io/tls"
  data = {
    "tls.crt" = tls_self_signed_cert.alb_to_istio[0].cert_pem
    "tls.key" = tls_private_key.alb_to_istio[0].private_key_pem
  }

  depends_on = [
    helm_release.istio_ingress_gateway,
  ]
}

###
# Terraform-managed Istio Gateways (ALB -> Istio HTTPS)
#
# We create a dedicated public gateway and use hosts ["*"] to avoid SNI
# filter_chain_not_found when the ALB does not send SNI to HTTPS targets.
###

resource "kubectl_manifest" "istio_public_gateway" {
  count = local.istio_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "networking.istio.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = local.istio_public_gateway_name
      namespace = local.gdcn_namespace
    }
    spec = {
      selector = {
        istio = local.istio_ingress_label
      }
      servers = [
        {
          port = {
            name     = "https-alb-backend-tls"
            number   = 443
            protocol = "HTTPS"
          }
          hosts = ["*"]
          tls = {
            credentialName = local.istio_backend_tls_secret_name
            mode           = "SIMPLE"
          }
        },
        {
          port = {
            name     = "http"
            number   = 80
            protocol = "HTTP"
          }
          hosts = ["*"]
        }
      ]
    }
  })

  depends_on = [
    kubernetes_namespace.gdcn,
    helm_release.istiod,
    kubernetes_secret.istio_backend_tls_ingress,
  ]
}

# Helm creates the Dex Gateway. We apply this manifest after the chart to ensure
# it has an HTTPS server and SNI-less hosts for ALB->Istio HTTPS.
resource "kubectl_manifest" "istio_dex_gateway" {
  count = local.istio_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "networking.istio.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = local.istio_dex_gateway_name
      namespace = local.gdcn_namespace
    }
    spec = {
      selector = {
        istio = local.istio_ingress_label
      }
      servers = [
        {
          port = {
            name     = "https-dex"
            number   = 443
            protocol = "HTTPS"
          }
          hosts = ["*"]
          tls = {
            credentialName = local.istio_backend_tls_secret_name
            mode           = "SIMPLE"
          }
        },
        {
          port = {
            name     = "http-dex"
            number   = 80
            protocol = "HTTP"
          }
          hosts = ["*"]
        }
      ]
    }
  })

  depends_on = [
    helm_release.gooddata_cn,
    kubernetes_secret.istio_backend_tls_ingress,
  ]
}
