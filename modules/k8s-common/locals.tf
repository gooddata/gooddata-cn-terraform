locals {
  gdcn_namespace                = "gooddata-cn"
  gdcn_service_account_name     = "gooddata-cn"
  istio_backend_tls_secret_name = "alb-backend-tls"
  istio_dex_gateway_name        = "gooddata-cn-dex-gateway"
  istio_public_gateway_name     = "alb-public-gateway"

  # Reuse a single ingress class name throughout the module
  resolved_ingress_class_name = trimspace(var.ingress_class_name_override) != "" ? trimspace(var.ingress_class_name_override) : (
    var.ingress_controller == "alb" ? "alb" : "nginx"
  )

  # Normalize wildcard provider input to avoid trailing/leading spaces
  resolved_wildcard_dns_provider = trimspace(var.wildcard_dns_provider)
}

