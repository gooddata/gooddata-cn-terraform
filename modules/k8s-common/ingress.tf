###
# Deploy ingress-nginx to Kubernetes with cloud-specific settings
###

locals {
  deploy_ingress_nginx = var.ingress_controller == "ingress-nginx"

  ingress_values = {
    controller = merge(
      {
        replicaCount = var.ingress_nginx_replica_count
        image = {
          registry = var.registry_k8sio
        }
        admissionWebhooks = {
          patch = {
            image = {
              registry = var.registry_k8sio
            }
          }
        }
        config = {
          allow-snippet-annotations   = "true"
          strict-validate-path-type   = "false"
          client-body-buffer-size     = "10m"
          client-body-timeout         = "180"
          large-client-header-buffers = "4 32k"
          client-header-buffer-size   = "32k"
          proxy-buffer-size           = "16k"
          brotli-types                = "application/vnd.gooddata.api+json application/xml+rss application/atom+xml application/javascript application/x-javascript application/json application/rss+xml application/vnd.ms-fontobject application/x-font-ttf application/x-web-app-manifest+json application/xhtml+xml application/xml font/opentype image/svg+xml image/x-icon text/css text/javascript text/plain text/x-component"
          enable-brotli               = "true"
          use-gzip                    = "true"
          gzip-types                  = "application/vnd.gooddata.api+json application/xml+rss application/atom+xml application/javascript application/x-javascript application/json application/rss+xml application/vnd.ms-fontobject application/x-font-ttf application/x-web-app-manifest+json application/xhtml+xml application/xml font/opentype image/svg+xml image/x-icon text/css text/javascript text/plain text/x-component"
        }
        addHeaders = {
          Permission-Policy         = "geolocation 'none'; midi 'none'; sync-xhr 'none'; microphone 'none'; camera 'none'; magnetometer 'none'; gyroscope 'none'; fullscreen 'none'; payment 'none';"
          Strict-Transport-Security = "max-age=31536000; includeSubDomains"
        }
      },
      var.cloud == "aws" ? {
        service = {
          annotations = merge(
            {
              "service.beta.kubernetes.io/aws-load-balancer-backend-protocol"                  = "tcp"
              "service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled" = "true"
              "service.beta.kubernetes.io/aws-load-balancer-type"                              = "external"
              "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type"                   = "ip"
              "service.beta.kubernetes.io/aws-load-balancer-target-group-attributes"           = "deregistration_delay.connection_termination.enabled=true,preserve_client_ip.enabled=true"
              "service.beta.kubernetes.io/aws-load-balancer-scheme"                            = "internet-facing"
              "service.beta.kubernetes.io/aws-load-balancer-healthcheck-port"                  = "10254"
              "service.beta.kubernetes.io/aws-load-balancer-healthcheck-path"                  = "/healthz"
              "service.beta.kubernetes.io/aws-load-balancer-healthcheck-protocol"              = "HTTP"
              "service.beta.kubernetes.io/aws-load-balancer-name"                              = "${var.deployment_name}-ingress"
              "service.beta.kubernetes.io/aws-load-balancer-alpn-policy"                       = "HTTP2Preferred"
            },
            var.ingress_eip_allocations == "" ? {} : {
              "service.beta.kubernetes.io/aws-load-balancer-eip-allocations" = var.ingress_eip_allocations
            }
          )
        }
      } : {},
      var.cloud == "azure" ? {
        service = {
          type = "LoadBalancer"
          annotations = {
            "service.beta.kubernetes.io/azure-load-balancer-resource-group"            = var.azure_resource_group_name
            "service.beta.kubernetes.io/azure-pip-name"                                = var.azure_ingress_pip_name
            "service.beta.kubernetes.io/azure-pip-tags"                                = "Project=${var.deployment_name}"
            "service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path" = "/healthz"
          }
        }
      } : {}
    )
  }
}

resource "kubernetes_namespace" "ingress" {
  count = local.deploy_ingress_nginx ? 1 : 0

  metadata {
    name = "ingress-nginx"
  }
}

resource "helm_release" "ingress_nginx" {
  count = local.deploy_ingress_nginx ? 1 : 0

  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  namespace  = kubernetes_namespace.ingress[count.index].metadata[0].name
  version    = var.helm_ingress_nginx_version

  values = [yamlencode(local.ingress_values)]

  depends_on = [
    kubernetes_namespace.ingress
  ]
}

