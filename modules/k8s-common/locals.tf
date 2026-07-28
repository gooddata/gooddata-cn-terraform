locals {
  gdcn_service_account_name      = "gooddata-cn"
  istio_public_gateway_name      = "istio-public-gateway"
  istio_public_tls_secret_name   = "gdcn-istio-gateway-tls"
  starrocks_namespace            = "starrocks"
  starrocks_service_account_name = "starrocks"

  use_ingress_nginx = var.ingress_controller == "ingress-nginx"
  use_lets_encrypt  = var.tls_mode == "letsencrypt"
  use_self_signed   = var.tls_mode == "selfsigned"
  use_cert_manager  = local.use_lets_encrypt || local.use_self_signed
  use_istio_gateway = var.ingress_controller == "istio_gateway"

  cert_manager_cluster_issuer_name = local.use_self_signed ? "selfsigned" : "letsencrypt"

  # Reuse a single ingress class name throughout the module
  resolved_ingress_class_name = lookup({ alb = "alb", istio_gateway = "" }, var.ingress_controller, "nginx")

  # Shared across the ingress-nginx Service (ingress.tf) and the Istio ingress
  # gateway Service (istio.tf) — the standard AWS NLB posture for both.
  aws_nlb_common_annotations = {
    "service.beta.kubernetes.io/aws-load-balancer-type"                              = "external"
    "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type"                   = "ip"
    "service.beta.kubernetes.io/aws-load-balancer-scheme"                            = "internet-facing"
    "service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled" = "true"
  }

  # Shared istio-injection namespace label, applied when the Istio gateway is in use.
  istio_injection_labels = local.use_istio_gateway ? {
    "istio-injection" = "enabled"
  } : null

  # Shared cert-manager cluster-issuer annotation fragment, merged into ingress
  # annotations wherever cert-manager manages the TLS certificate.
  cert_manager_issuer_annotation = local.use_cert_manager ? {
    "cert-manager.io/cluster-issuer" = local.cert_manager_cluster_issuer_name
  } : {}

  # Autoscaling bounds: dev runs single replicas, production keeps an HA floor.
  gdcn_autoscaling_min_replicas = var.gdcn_size == "dev" ? 1 : 2
  gdcn_autoscaling_max_replicas = var.gdcn_size == "dev" ? 3 : 5
}

