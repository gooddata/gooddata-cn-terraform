output "aws_region" { value = var.aws_region }
output "aws_profile_name" { value = var.aws_profile_name }
output "ingress_controller" { value = var.ingress_controller }
output "auth_hostname" { value = module.k8s_common.auth_hostname }
output "org_domains" { value = module.k8s_common.org_domains }
output "org_ids" { value = module.k8s_common.org_ids }
output "ingress_class_name" { value = module.k8s_common.ingress_class_name }

locals {
  use_istio_gateway = var.ingress_controller == "istio_gateway"

  # Must match the deterministic name set on the Istio gateway Service in modules/k8s-common/istio.tf
  istio_nlb_base_name          = "${var.deployment_name}-istio"
  istio_nlb_name_sanitized     = replace(lower(local.istio_nlb_base_name), "/[^a-z0-9-]/", "-")
  istio_nlb_load_balancer_name = local.use_istio_gateway ? substr(local.istio_nlb_name_sanitized, 0, min(length(local.istio_nlb_name_sanitized), 32)) : ""
}

data "external" "istio_gateway_lb" {
  count = local.use_istio_gateway ? 1 : 0

  program = [
    "bash", "-c",
    <<-EOT
      set -euo pipefail
      hostname=$(aws elbv2 describe-load-balancers \
        --names "${local.istio_nlb_load_balancer_name}" \
        --region "${var.aws_region}" \
        --profile "${var.aws_profile_name}" \
        --query 'LoadBalancers[0].DNSName' \
        --output text 2>/dev/null || echo "")
      [ "$hostname" = "None" ] && hostname=""
      printf '{"hostname":"%s"}' "$hostname"
    EOT
  ]

  depends_on = [module.k8s_common]
}

locals {
  # Target that user should point DNS at (may be empty early in provisioning).
  manual_dns_target = local.use_alb ? (
    length(data.aws_lb.gdcn) > 0 ? trimspace(data.aws_lb.gdcn[0].dns_name) : ""
    ) : (local.use_istio_gateway ? (
      length(data.external.istio_gateway_lb) > 0 ? trimspace(try(data.external.istio_gateway_lb[0].result.hostname, "")) : ""
      ) : (
      length(data.external.ingress_nginx_lb) > 0 ? trimspace(try(data.external.ingress_nginx_lb[0].result.hostname, "")) : ""
  ))
}

output "manual_dns_records" {
  description = "DNS records to create when dns_provider is self-managed."
  value = var.dns_provider == "self-managed" && local.manual_dns_target != "" ? [
    for hostname in distinct(compact(concat([module.k8s_common.auth_hostname], module.k8s_common.org_domains))) : {
      hostname    = hostname
      record_type = "CNAME"
      records     = [local.manual_dns_target]
    }
  ] : []
}

output "acm_validation_records" {
  description = "ACM certificate validation DNS records. Create these in your DNS provider when using ALB + ACM with self-managed DNS."
  value = var.dns_provider == "self-managed" && var.tls_mode == "acm" && length(aws_acm_certificate.gdcn) > 0 ? [
    for option in aws_acm_certificate.gdcn[0].domain_validation_options : {
      name  = option.resource_record_name
      type  = option.resource_record_type
      value = option.resource_record_value
    }
  ] : []
}
