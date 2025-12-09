###
# AWS Application Load Balancer ingress support
###

locals {
  alb_wildcard_domain  = local.use_alb && local.base_domain != "" ? "*.${local.base_domain}" : ""
  alb_certificate_sans = []
  alb_acm_enabled      = local.alb_wildcard_domain != ""
}

resource "aws_acm_certificate" "gdcn" {
  count = local.alb_acm_enabled ? 1 : 0

  domain_name               = local.alb_wildcard_domain
  subject_alternative_names = local.alb_certificate_sans
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
  for_each = local.alb_acm_enabled ? {
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
  count = local.alb_acm_enabled ? 1 : 0

  certificate_arn         = aws_acm_certificate.gdcn[0].arn
  validation_record_fqdns = [for record in aws_route53_record.gdcn_acm_validation : record.fqdn]
}

data "aws_lb" "gdcn" {
  count = local.use_alb ? 1 : 0

  name = local.alb_load_balancer_name

  depends_on = [
    module.k8s_common
  ]

  timeouts {
    read = "10m"
  }
}

