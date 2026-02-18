###
# Install Istio (optional)
#
# When ingress_controller = "istio_gateway", we install Istio.
###

locals {
  istio_enabled       = var.ingress_controller == "istio_gateway"
  istio_chart_repo    = "https://istio-release.storage.googleapis.com/charts"
  istio_system_ns     = "istio-system"
  istio_ingress_ns    = "istio-ingress"
  istio_ingress_name  = "istio-ingress"
  istio_ingress_label = "ingressgateway"

  # Hosts that must be accepted by the external Gateway.
  # auth_hostname is required by root module validation; org hostnames may be empty.
  istio_gateway_hosts = distinct(compact(concat(
    [trimspace(var.auth_hostname)],
    [for org in var.gdcn_orgs : trimspace(org.hostname)]
  )))

  # Deterministic AWS NLB name for the public Istio gateway Service.
  # Used by AWS outputs to look up the NLB DNS name when dns_provider=self-managed.
  aws_istio_nlb_base_name          = "${var.deployment_name}-istio"
  aws_istio_nlb_name_sanitized     = replace(lower(local.aws_istio_nlb_base_name), "/[^a-z0-9-]/", "-")
  aws_istio_nlb_load_balancer_name = var.cloud == "aws" && local.istio_enabled ? substr(local.aws_istio_nlb_name_sanitized, 0, min(length(local.aws_istio_nlb_name_sanitized), 32)) : ""
}

###
# Istio Installation (base → istiod → ingress gateway)
###

resource "kubernetes_namespace_v1" "istio_system" {
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
  namespace  = kubernetes_namespace_v1.istio_system[0].metadata[0].name

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
  namespace  = kubernetes_namespace_v1.istio_system[0].metadata[0].name

  values = [yamlencode({
    meshConfig = { accessLogFile = "/dev/stdout" }
    global = merge(
      # Native sidecars start the Envoy proxy before init containers, so
      # init containers participate in mTLS and the mesh from the start.
      { proxy = { nativeSidecar = true } },
      # Route Istio images through the pull-through cache when enabled
      var.enable_image_cache ? { hub = "${var.registry_dockerio}/istio" } : {}
    )
    pilot = {
      env = {
        # Enable reconciliation of Kubernetes Ingress resources (needed for cert-manager HTTP-01
        # when we use ingress class "istio").
        PILOT_ENABLE_K8S_INGRESS = "true"
        # Must match global.proxy.nativeSidecar — the env var controls the
        # .NativeSidecars template variable that istiod uses at injection time.
        ENABLE_NATIVE_SIDECARS = "true"
      }
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
      type = "LoadBalancer"
      ports = [
        { name = "status-port", port = 15021, targetPort = 15021, protocol = "TCP" },
        { name = "http2", port = 80, targetPort = 8080, protocol = "TCP" },
        { name = "https", port = 443, targetPort = 8443, protocol = "TCP" },
      ]
      annotations = merge(
        { "external-dns.alpha.kubernetes.io/hostname" = join(",", local.istio_gateway_hosts) },
        var.cloud == "aws" ? {
          "service.beta.kubernetes.io/aws-load-balancer-name"                              = local.aws_istio_nlb_load_balancer_name
          "service.beta.kubernetes.io/aws-load-balancer-type"                              = "external"
          "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type"                   = "ip"
          "service.beta.kubernetes.io/aws-load-balancer-scheme"                            = "internet-facing"
          "service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled" = "true"
        } : {}
      )
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
# Istio Configuration (IngressClass, mTLS, TLS Certificate, Gateway)
###

# IngressClass for cert-manager HTTP-01 solver
resource "kubectl_manifest" "ingressclass_istio" {
  count = local.use_istio_gateway && local.use_cert_manager ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "IngressClass"
    metadata   = { name = "istio" }
    spec       = { controller = "istio.io/ingress-controller" }
  })

  depends_on = [
    helm_release.istiod,
  ]
}

# Public TLS certificate (cert-manager / Let's Encrypt)
resource "kubectl_manifest" "istio_public_tls_certificate" {
  count = local.use_istio_gateway && local.use_cert_manager ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "gdcn-istio-gateway"
      namespace = local.istio_ingress_ns
    }
    spec = {
      secretName = local.istio_public_tls_secret_name
      issuerRef = {
        name = var.tls_mode
        kind = "ClusterIssuer"
      }
      dnsNames = local.istio_gateway_hosts
    }
  })

  depends_on = [
    kubectl_manifest.letsencrypt_cluster_issuer,
    kubectl_manifest.selfsigned_cluster_issuer,
    helm_release.istio_ingress_gateway,
  ]
}

# Terraform-managed Istio Gateway used by the GoodData.CN chart.
# We set `istio.gateway.existingGateway` in `gdcn-istio.yaml.tftpl`, so the
# chart (and organization-controller) won't create/manage Gateway resources
# and will reference this Gateway from its VirtualServices (including Dex).
resource "kubectl_manifest" "istio_public_gateway" {
  count = local.istio_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "networking.istio.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = local.istio_public_gateway_name
      namespace = local.istio_ingress_ns
    }
    spec = {
      selector = { istio = local.istio_ingress_label }
      servers = [
        # HTTPS with TLS termination at Istio Gateway
        {
          port  = { name = "https", number = 443, protocol = "HTTPS" }
          hosts = local.istio_gateway_hosts
          tls   = { credentialName = local.istio_public_tls_secret_name, mode = "SIMPLE" }
        },
        # HTTP → HTTPS redirect
        {
          port  = { name = "http", number = 80, protocol = "HTTP" }
          hosts = local.istio_gateway_hosts
          tls   = { httpsRedirect = true }
        },
      ]
    }
  })

  depends_on = [
    helm_release.istio_ingress_gateway,
  ]

  lifecycle {
    precondition {
      condition     = length(local.istio_gateway_hosts) > 0
      error_message = "istio_gateway_hosts must not be empty. Set auth_hostname and/or gdcn_orgs[*].hostname."
    }
  }
}
