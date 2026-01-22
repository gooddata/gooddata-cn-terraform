output "aws_region" { value = var.aws_region }
output "aws_profile_name" { value = var.aws_profile_name }
output "ingress_controller" { value = var.ingress_controller }
output "auth_hostname" { value = module.k8s_common.auth_hostname }
output "org_domains" { value = module.k8s_common.org_domains }
output "org_ids" { value = module.k8s_common.org_ids }
output "ingress_class_name" { value = module.k8s_common.ingress_class_name }

output "manual_dns_records" {
  description = "DNS records to create when dns_provider is self-managed."
  value = var.dns_provider == "self-managed" ? [
    for hostname in distinct(compact(concat([module.k8s_common.auth_hostname], module.k8s_common.org_domains))) : {
      hostname    = hostname
      record_type = "CNAME"
      records = local.use_alb ? (
        length(data.aws_lb.gdcn) > 0 ? [data.aws_lb.gdcn[0].dns_name] : []
        ) : (
        length(data.external.ingress_nginx_lb) > 0 ? [data.external.ingress_nginx_lb[0].result.hostname] : []
      )
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
