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

  # Deterministic AWS NLB name for the public Istio gateway Service.
  # Used by AWS outputs to look up the NLB DNS name when dns_provider=self-managed.
  aws_istio_nlb_base_name          = "${var.deployment_name}-istio"
  aws_istio_nlb_name_sanitized     = replace(lower(local.aws_istio_nlb_base_name), "/[^a-z0-9-]/", "-")
  aws_istio_nlb_load_balancer_name = var.cloud == "aws" && local.istio_enabled ? substr(local.aws_istio_nlb_name_sanitized, 0, min(length(local.aws_istio_nlb_name_sanitized), 32)) : ""

  # Hosts that must be accepted by the external Gateway.
  # auth_hostname is required by root module validation; org hostnames may be empty.
  istio_gateway_hosts = distinct(compact(concat(
    [trimspace(var.auth_hostname)],
    [for org in var.gdcn_orgs : trimspace(org.hostname)]
  )))

  istio_gateway_server_http = {
    port = {
      name     = "http"
      number   = 80
      protocol = "HTTP"
    }
    hosts = local.istio_gateway_hosts
  }

  # Public TLS termination at the Istio Gateway (istio_gateway mode).
  istio_gateway_server_https_public_tls = {
    port = {
      name     = "https"
      number   = 443
      protocol = "HTTPS"
    }
    hosts = local.istio_gateway_hosts
    tls = {
      credentialName = local.istio_public_tls_secret_name
      mode           = "SIMPLE"
    }
  }

  istio_gateway_servers = [
    local.istio_gateway_server_https_public_tls,
    local.istio_gateway_server_http,
  ]

  # Service shape for the Istio ingress gateway chart values.
  # istio_gateway -> LoadBalancer (public LB directly to Istio ingress gateway)
  istio_gateway_service_type = "LoadBalancer"

  istio_gateway_service_ports = [
    # Status port used by the gateway readiness endpoint.
    # https://istio.io/latest/docs/ops/configuration/traffic-management/proxy-protocol/
    {
      name       = "status-port"
      port       = 15021
      targetPort = 15021
      protocol   = "TCP"
    },
    {
      name = "http2"
      port = 80
      # Istio gateway listens on 8080 for HTTP by default.
      targetPort = 8080
      protocol   = "TCP"
    },
    {
      name = "https"
      port = 443
      # Istio gateway listens on 8443 for HTTPS by default.
      targetPort = 8443
      protocol   = "TCP"
    }
  ]

  # Drop null keys (e.g. nodePort when ClusterIP) so chart schema validation passes.
  istio_gateway_service_ports_for_values = [
    for p in local.istio_gateway_service_ports : {
      for k, v in p : k => v if v != null
    }
  ]

  # Service annotations for public Istio ingress gateway.
  istio_gateway_service_annotations = local.use_istio_gateway ? merge(
    {
      "external-dns.alpha.kubernetes.io/hostname" = join(",", local.istio_gateway_hosts)
    },
    var.cloud == "aws" ? {
      "service.beta.kubernetes.io/aws-load-balancer-name"                              = local.aws_istio_nlb_load_balancer_name
      "service.beta.kubernetes.io/aws-load-balancer-type"                              = "external"
      "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type"                   = "ip"
      "service.beta.kubernetes.io/aws-load-balancer-scheme"                            = "internet-facing"
      "service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled" = "true"
    } : {}
  ) : {}
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

  values = [<<-EOF
    meshConfig:
      accessLogFile: /dev/stdout
    pilot:
      env:
        # Enable reconciliation of Kubernetes Ingress resources (needed for cert-manager HTTP-01
        # when we use ingress class "istio").
        PILOT_ENABLE_K8S_INGRESS: "true"
    EOF
  ]

  wait          = true
  wait_for_jobs = true
  timeout       = 1800

  depends_on = [
    helm_release.istio_base,
  ]
}

###
# Kubernetes IngressClass for Istio (used by cert-manager HTTP-01 solver)
###
resource "kubectl_manifest" "ingressclass_istio" {
  count = local.use_istio_gateway && local.use_cert_manager ? 1 : 0

  yaml_body = <<-YAML
    apiVersion: networking.k8s.io/v1
    kind: IngressClass
    metadata:
      name: istio
    spec:
      controller: istio.io/ingress-controller
  YAML

  depends_on = [
    helm_release.istiod,
  ]
}

###
# Enforce STRICT mTLS within workload namespaces
###

# Default PeerAuthentication in the GoodData.CN namespace.
# This enforces mTLS for all inbound traffic to workloads in the namespace.
resource "kubectl_manifest" "peerauth_gdcn_strict" {
  count = local.istio_enabled ? 1 : 0

  yaml_body = <<-YAML
    apiVersion: security.istio.io/v1beta1
    kind: PeerAuthentication
    metadata:
      name: default
      namespace: ${local.gdcn_namespace}
    spec:
      mtls:
        mode: STRICT
  YAML

  depends_on = [
    kubernetes_namespace.gdcn,
    helm_release.istio_base,
    helm_release.istiod,
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
      type        = local.istio_gateway_service_type
      ports       = local.istio_gateway_service_ports_for_values
      annotations = local.istio_gateway_service_annotations
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
# Public TLS certificate for istio_gateway mode (cert-manager / Let's Encrypt)
###
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
        name = "letsencrypt"
        kind = "ClusterIssuer"
      }
      dnsNames = local.istio_gateway_hosts
    }
  })

  depends_on = [
    kubectl_manifest.letsencrypt_cluster_issuer,
    helm_release.istio_ingress_gateway,
  ]
}

###
# Terraform-managed Istio Gateway used by the GoodData.CN chart.
#
# We set `istio.gateway.existingGateway` in `gdcn-istio.yaml.tftpl`, so the
# chart (and organization-controller) will NOT create/manage Gateway resources
# and will reference this Gateway from its VirtualServices (including Dex).
###

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
      selector = {
        istio = local.istio_ingress_label
      }
      servers = local.istio_gateway_servers
    }
  })

  depends_on = [
    helm_release.istio_ingress_gateway,
    helm_release.istiod,
  ]

  lifecycle {
    precondition {
      condition     = length(local.istio_gateway_hosts) > 0
      error_message = "istio_gateway_hosts must not be empty. Set auth_hostname and/or gdcn_orgs[*].hostname."
    }
  }
}
