###
# Deploy Traefik to Kubernetes with cloud-specific settings
###

locals {
  traefik_namespace = "traefik"

  # Applied to every router on the websecure entrypoint, so no Ingress can drop
  # them by overriding its annotations.
  traefik_entrypoint_middlewares = [for name in keys(local.traefik_middlewares) : "${local.traefik_namespace}-${name}@kubernetescrd"]

  traefik_middlewares = {
    default-headers = {
      headers = {
        customResponseHeaders = {
          "Permissions-Policy"        = "geolocation=(), midi=(), sync-xhr=(), microphone=(), camera=(), magnetometer=(), gyroscope=(), fullscreen=(), payment=()"
          "Strict-Transport-Security" = "max-age=31536000; includeSubDomains"
        }
      }
    }
    # Text types only: images, PDFs and XLSX exports are already compressed.
    compress = {
      compress = {
        includedContentTypes = [
          "application/atom+xml", "application/javascript", "application/json",
          "application/rss+xml", "application/vnd.gooddata.api+json", "application/vnd.ms-fontobject",
          "application/x-font-ttf", "application/x-javascript", "application/x-web-app-manifest+json",
          "application/xhtml+xml", "application/xml", "application/xml+rss", "font/opentype",
          "image/svg+xml", "image/x-icon", "text/css", "text/html", "text/javascript",
          "text/plain", "text/x-component",
        ]
      }
    }
  }

  traefik_values = {
    image = {
      registry = var.registry_dockerio
      # Official Docker Hub images live under library/; only docker.io adds it implicitly.
      repository = "library/traefik"
    }

    deployment = {
      replicas = var.ingress_replicas
    }

    # A PDB (which NAP/Karpenter honors) plus cross-node spread keep at least one
    # replica serving through node consolidation.
    podDisruptionBudget = {
      enabled      = var.ingress_replicas > 1
      minAvailable = 1
    }
    topologySpreadConstraints = [{
      maxSkew           = 1
      topologyKey       = "kubernetes.io/hostname"
      whenUnsatisfiable = "ScheduleAnyway"
      labelSelector = {
        matchLabels = { "app.kubernetes.io/name" = "traefik" }
      }
    }]

    providers = {
      kubernetesIngress = {
        enabled          = true
        publishedService = { enabled = true }
      }
      kubernetesCRD = { enabled = true }
    }

    ingressClass = {
      enabled        = true
      isDefaultClass = false
      name           = "traefik"
    }

    ports = {
      web = {
        forwardedHeaders = { insecure = var.ingress_behind_l7 }
        # Redirect HTTP to HTTPS. Behind an L7 proxy, the proxy owns the redirect,
        # and a redirect here would loop. Let's Encrypt follows it for HTTP-01.
        http = {
          redirections = {
            entryPoint = var.ingress_behind_l7 ? null : { to = "websecure", scheme = "https", permanent = true }
          }
        }
      }
      websecure = {
        forwardedHeaders = { insecure = var.ingress_behind_l7 }
        http             = { middlewares = local.traefik_entrypoint_middlewares }
        # The 60s default caps the whole request read, which cuts off large uploads.
        transport = { respondingTimeouts = { readTimeout = "600s" } }
      }
    }

    service = merge(
      {
        enabled = true
        spec    = { type = "LoadBalancer" }
      },
      var.cloud == "aws" ? {
        annotations = merge(local.aws_nlb_common_annotations, {
          "service.beta.kubernetes.io/aws-load-balancer-backend-protocol"        = "tcp"
          "service.beta.kubernetes.io/aws-load-balancer-target-group-attributes" = "deregistration_delay.connection_termination.enabled=true,preserve_client_ip.enabled=true"
          # IP targets register pod IPs, so the NLB can probe /ping on the admin port (8080).
          "service.beta.kubernetes.io/aws-load-balancer-healthcheck-port"     = "8080"
          "service.beta.kubernetes.io/aws-load-balancer-healthcheck-path"     = "/ping"
          "service.beta.kubernetes.io/aws-load-balancer-healthcheck-protocol" = "HTTP"
          "service.beta.kubernetes.io/aws-load-balancer-name"                 = "${var.deployment_name}-ingress"
          "service.beta.kubernetes.io/aws-load-balancer-alpn-policy"          = "HTTP2Preferred"
        })
      } : {},
      # Azure and STACKIT probe a Service port over TCP. /ping is on the admin port,
      # which the Service does not expose, so no probe-path annotation is set.
    )

    metrics = var.enable_observability ? {
      prometheus = {
        service        = { enabled = true }
        serviceMonitor = { enabled = true }
      }
    } : {}
  }
}

resource "kubernetes_namespace_v1" "ingress" {
  count = local.use_traefik ? 1 : 0

  metadata {
    name = local.traefik_namespace
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

# The chart installs the Middleware CRD, so these apply after the release. Until
# they exist, websecure routers fail with a missing-middleware error.
resource "kubectl_manifest" "traefik_middleware" {
  for_each = local.use_traefik ? toset(keys(local.traefik_middlewares)) : []

  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = each.key
      namespace = kubernetes_namespace_v1.ingress[0].metadata[0].name
    }
    spec = local.traefik_middlewares[each.key]
  })

  depends_on = [helm_release.traefik]
}
