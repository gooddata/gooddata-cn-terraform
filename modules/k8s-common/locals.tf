locals {
  # Reuse a single ingress class name throughout the module
  resolved_ingress_class_name = trimspace(var.ingress_class_name_override) != "" ? trimspace(var.ingress_class_name_override) : "nginx"

  # Normalize wildcard provider input to avoid trailing/leading spaces
  resolved_wildcard_dns_provider = trimspace(var.wildcard_dns_provider)
}

