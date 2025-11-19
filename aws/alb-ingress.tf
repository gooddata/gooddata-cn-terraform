###
# AWS Application Load Balancer ingress support
###

locals {
  alb_host_records = local.use_alb ? {
    for entry in [
      { key = "auth", value = local.default_auth_domain },
      { key = "org", value = local.default_org_domain }
    ] : entry.key => entry.value if trimspace(entry.value) != ""
  } : {}
}

resource "aws_acm_certificate" "gdcn" {
  count = local.use_alb ? 1 : 0

  domain_name               = local.default_org_domain
  subject_alternative_names = local.default_auth_domain != local.default_org_domain ? compact([local.default_auth_domain]) : []
  validation_method         = "DNS"

  tags = merge(
    {
      Name = "${var.deployment_name}-gdcn-alb-cert"
    },
    var.aws_additional_tags
  )

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "gdcn_acm_validation" {
  for_each = local.use_alb ? {
    for option in aws_acm_certificate.gdcn[0].domain_validation_options :
    option.domain_name => {
      name  = option.resource_record_name
      type  = option.resource_record_type
      value = option.resource_record_value
    }
  } : {}

  zone_id = var.route53_zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.value]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "gdcn" {
  count = local.use_alb ? 1 : 0

  certificate_arn         = aws_acm_certificate.gdcn[0].arn
  validation_record_fqdns = [for record in aws_route53_record.gdcn_acm_validation : record.fqdn]
}

data "aws_lb" "gdcn" {
  count = local.use_alb ? 1 : 0

  name = local.alb_load_balancer_name

  # Ensure the Kubernetes ingress resources are created before querying AWS.
  depends_on = [
    module.k8s_common
  ]
}

resource "aws_route53_record" "gdcn_hosts" {
  for_each = local.use_alb ? local.alb_host_records : {}

  zone_id = var.route53_zone_id
  name    = each.value
  type    = "A"

  alias {
    name                   = try(data.aws_lb.gdcn[0].dns_name, "")
    zone_id                = try(data.aws_lb.gdcn[0].zone_id, "")
    evaluate_target_health = false
  }

  depends_on = [
    data.aws_lb.gdcn
  ]
}


