locals {
  gdcn_namespace               = "gooddata-cn"
  gdcn_service_account_name    = "gooddata-cn"
  istio_public_gateway_name    = "istio-public-gateway"
  istio_public_tls_secret_name = "gdcn-istio-gateway-tls"

  use_alb           = var.ingress_controller == "alb"
  use_ingress_nginx = var.ingress_controller == "ingress-nginx"
  use_cert_manager  = var.tls_mode == "letsencrypt"
  use_istio_gateway = var.ingress_controller == "istio_gateway"

  # Reuse a single ingress class name throughout the module
  resolved_ingress_class_name = var.ingress_controller == "alb" ? "alb" : "nginx"
}

