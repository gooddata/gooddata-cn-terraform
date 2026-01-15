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
    local.common_tags,
    {
      Name = "${var.deployment_name}-gdcn-alb-cert"
    }
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

data "external" "alb_wait" {
  count = local.use_alb ? 1 : 0

  program = [
    "bash",
    "-c",
    <<-EOT
      set -euo pipefail

      if ! command -v aws >/dev/null 2>&1; then
        echo "The aws CLI is required to wait for the ALB. Install awscli or disable ALB mode." >&2
        exit 1
      fi

      lb_name="${local.alb_load_balancer_name}"
      aws_region="${var.aws_region}"
      aws_profile="${var.aws_profile_name}"

      timeout_seconds=900
      interval_seconds=10
      end=$((SECONDS + timeout_seconds))

      while true; do
        if out="$(
          aws elbv2 describe-load-balancers \
            --names "$lb_name" \
            --region "$aws_region" \
            --profile "$aws_profile" \
            --query 'LoadBalancers[0].{dns_name:DNSName,zone_id:CanonicalHostedZoneId,arn:LoadBalancerArn}' \
            --output json 2>/dev/null
        )"; then
          echo "$out"
          exit 0
        fi

        if [ "$SECONDS" -ge "$end" ]; then
          echo "Timed out waiting for ALB '$lb_name' to exist." >&2
          exit 1
        fi

        sleep "$interval_seconds"
      done
    EOT
  ]

  depends_on = [
    module.k8s_common,
    kubernetes_ingress_v1.alb_to_istio,
  ]
}

data "aws_lb" "gdcn" {
  count = local.use_alb ? 1 : 0

  name = local.alb_load_balancer_name

  depends_on = [
    module.k8s_common,
    data.external.alb_wait
  ]

  timeouts {
    read = "10m"
  }
}

