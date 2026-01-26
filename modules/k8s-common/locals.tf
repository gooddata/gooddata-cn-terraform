locals {
  gdcn_namespace                = "gooddata-cn"
  gdcn_service_account_name     = "gooddata-cn"
  istio_backend_tls_secret_name = "alb-backend-tls"
  istio_dex_gateway_name        = "gooddata-cn-dex-gateway"
  istio_public_gateway_name     = "alb-public-gateway"

  use_ingress_nginx = var.ingress_controller == "ingress-nginx"
  use_cert_manager  = var.tls_mode == "cert-manager"

  # Reuse a single ingress class name throughout the module
  resolved_ingress_class_name = var.ingress_controller == "alb" ? "alb" : "nginx"

}

