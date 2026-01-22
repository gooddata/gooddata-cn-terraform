###
# ALB → Istio ingress gateway (NodePort)
#
# Matches the AWS blog architecture:
# Route53 wildcard → ALB (ACM TLS) → Istio ingress gateway (NodePort) → Istio Gateway/VirtualService.
###

locals {
  use_alb_istio = var.ingress_controller == "alb" && var.enable_istio
}

resource "kubernetes_ingress_v1" "alb_to_istio" {
  count = local.use_alb_istio ? 1 : 0

  metadata {
    name      = "${var.deployment_name}-alb-istio"
    namespace = "istio-ingress"

    annotations = merge(
      local.alb_shared_annotations,
      {
        "alb.ingress.kubernetes.io/target-type"          = "instance"
        "alb.ingress.kubernetes.io/backend-protocol"     = "HTTPS"
        "alb.ingress.kubernetes.io/healthcheck-path"     = "/healthz/ready"
        "alb.ingress.kubernetes.io/healthcheck-port"     = "32021"
        "alb.ingress.kubernetes.io/healthcheck-protocol" = "HTTP"
        "alb.ingress.kubernetes.io/success-codes"        = "200-399"
      }
    )
  }

  spec {
    ingress_class_name = "alb"

    rule {
      host = "*.${local.base_domain}"

      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = "istio-ingress"
              port {
                number = 443
              }
            }
          }
        }
      }
    }
  }

  depends_on = [
    module.k8s_common,
    aws_acm_certificate_validation.gdcn,
  ]
}

