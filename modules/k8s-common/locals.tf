locals {
  gdcn_service_account_name    = "gooddata-cn"
  istio_public_gateway_name    = "istio-public-gateway"
  istio_public_tls_secret_name = "gdcn-istio-gateway-tls"

  use_alb           = var.ingress_controller == "alb"
  use_ingress_nginx = var.ingress_controller == "ingress-nginx"
  use_lets_encrypt  = var.tls_mode == "letsencrypt"
  use_self_signed   = var.tls_mode == "selfsigned"
  use_cert_manager  = local.use_lets_encrypt || local.use_self_signed
  use_istio_gateway = var.ingress_controller == "istio_gateway"

  cert_manager_cluster_issuer_name = local.use_self_signed ? "selfsigned" : "letsencrypt"

  # Reuse a single ingress class name throughout the module
  resolved_ingress_class_name = var.ingress_controller == "alb" ? "alb" : "nginx"
}

