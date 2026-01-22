locals {
  gdcn_namespace            = "gooddata-cn"
  gdcn_service_account_name = "gooddata-cn"

  use_ingress_nginx = var.ingress_controller == "ingress-nginx"
  use_cert_manager  = var.tls_mode == "cert-manager"

  # Reuse a single ingress class name throughout the module
  resolved_ingress_class_name = trimspace(var.ingress_class_name_override) != "" ? trimspace(var.ingress_class_name_override) : "nginx"
}

