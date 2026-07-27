###
# Deploy Traefik to Kubernetes with cloud-specific settings
###

locals {
  traefik_values = {
    image = {
      registry = var.registry_dockerio
    }

    deployment = {
      replicas = var.size_profile == "dev" ? 1 : 2
    }

    providers = {
      kubernetesIngress = {
        enabled = true
        publishedService = {
          enabled = true
        }
      }
      kubernetesCRD = {
        enabled = true
      }
    }

    ingressClass = {
      enabled        = true
      isDefaultClass = false
      name           = "traefik"
    }

    service = merge(
      {
        enabled = true
        spec    = { type = "LoadBalancer" }
      },
      var.cloud == "aws" ? {
        annotations = {
          "service.beta.kubernetes.io/aws-load-balancer-backend-protocol"                  = "tcp"
          "service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled" = "true"
          "service.beta.kubernetes.io/aws-load-balancer-type"                              = "external"
          "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type"                   = "ip"
          "service.beta.kubernetes.io/aws-load-balancer-target-group-attributes"           = "deregistration_delay.connection_termination.enabled=true,preserve_client_ip.enabled=true"
          "service.beta.kubernetes.io/aws-load-balancer-scheme"                            = "internet-facing"
          # Probe Traefik's admin entrypoint (8080) where /ping is served.
          # NLB IP target type registers pod IPs, and the admin port is open on the pod regardless of Service exposure.
          "service.beta.kubernetes.io/aws-load-balancer-healthcheck-port"     = "8080"
          "service.beta.kubernetes.io/aws-load-balancer-healthcheck-path"     = "/ping"
          "service.beta.kubernetes.io/aws-load-balancer-healthcheck-protocol" = "HTTP"
          "service.beta.kubernetes.io/aws-load-balancer-name"                 = "${var.deployment_name}-ingress"
          "service.beta.kubernetes.io/aws-load-balancer-alpn-policy"          = "HTTP2Preferred"
        }
      } : {},
      # Azure Standard LB probes one of the Service's declared ports (80/443), not arbitrary pod ports.
      # Traefik's /ping endpoint lives on the admin entrypoint (8080), which is not in the Service spec.
      # No health-probe-request-path annotation is set: Azure uses a TCP probe on port 80, which is
      # sufficient to validate that Traefik is accepting connections on its web entrypoint.
    )

    additionalArguments = var.ingress_behind_l7 ? [
      "--entryPoints.web.forwardedHeaders.insecure=true",
      "--entryPoints.websecure.forwardedHeaders.insecure=true",
    ] : []

    metrics = var.enable_observability ? {
      prometheus = {
        service = {
          enabled = true
        }
        serviceMonitor = {
          enabled = true
        }
      }
    } : {}
  }

  # Middleware references attached via the traefik.ingress.kubernetes.io/router.middlewares annotation.
  # Format is "<namespace>-<name>@kubernetescrd".
  traefik_ns                  = "traefik"
  traefik_default_middlewares = "${local.traefik_ns}-default-headers@kubernetescrd,${local.traefik_ns}-compress@kubernetescrd"
  traefik_gdcn_middlewares    = "${local.traefik_ns}-body-200m@kubernetescrd,${local.traefik_default_middlewares}"
  traefik_grafana_middlewares = "${local.traefik_ns}-body-50m@kubernetescrd,${local.traefik_default_middlewares}"
}

resource "kubernetes_namespace_v1" "ingress" {
  count = local.use_traefik ? 1 : 0

  metadata {
    name = "traefik"
  }
}

resource "helm_release" "traefik" {
  count = local.use_traefik ? 1 : 0

  name          = "traefik"
  repository    = "https://traefik.github.io/charts"
  chart         = "traefik"
  namespace     = kubernetes_namespace_v1.ingress[count.index].metadata[0].name
  version       = var.helm_traefik_version
  wait          = true
  wait_for_jobs = true
  timeout       = 1800

  values = [yamlencode(local.traefik_values)]

  depends_on = [
    kubernetes_namespace_v1.ingress,
    helm_release.kube_prometheus_stack,
  ]
}

# Middleware: Permission-Policy and HSTS headers attached to every GoodData/Grafana router.
resource "kubectl_manifest" "traefik_default_headers" {
  count = local.use_traefik ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "default-headers"
      namespace = kubernetes_namespace_v1.ingress[0].metadata[0].name
    }
    spec = {
      headers = {
        customResponseHeaders = {
          "Permission-Policy"         = "geolocation=(), midi=(), sync-xhr=(), microphone=(), camera=(), magnetometer=(), gyroscope=(), fullscreen=(), payment=()"
          "Strict-Transport-Security" = "max-age=31536000; includeSubDomains"
        }
      }
    }
  })

  depends_on = [helm_release.traefik]
}

# Middleware: gzip/brotli compression (Traefik v3 negotiates both).
resource "kubectl_manifest" "traefik_compress" {
  count = local.use_traefik ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "compress"
      namespace = kubernetes_namespace_v1.ingress[0].metadata[0].name
    }
    spec = {
      compress = {}
    }
  })

  depends_on = [helm_release.traefik]
}

# Middleware: 200 MiB request body cap for GoodData.CN ingress (Quiver datasource FS uploads).
resource "kubectl_manifest" "traefik_body_200m" {
  count = local.use_traefik ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "body-200m"
      namespace = kubernetes_namespace_v1.ingress[0].metadata[0].name
    }
    spec = {
      buffering = {
        maxRequestBodyBytes = 209715200
      }
    }
  })

  depends_on = [helm_release.traefik]
}

# Middleware: 50 MiB request body cap for Grafana ingress (exports).
resource "kubectl_manifest" "traefik_body_50m" {
  count = local.use_traefik ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "body-50m"
      namespace = kubernetes_namespace_v1.ingress[0].metadata[0].name
    }
    spec = {
      buffering = {
        maxRequestBodyBytes = 52428800
      }
    }
  })

  depends_on = [helm_release.traefik]
}
