###
# AWS Application Load Balancer ingress support
###

locals {
  auth_hostname = trimspace(var.auth_hostname)
  org_hostnames = distinct(compact([for org in var.gdcn_orgs : trimspace(org.hostname)]))
  alb_cert_domains = local.use_alb && var.tls_mode == "acm" ? distinct(compact(concat(
    [local.auth_hostname],
    local.org_hostnames
  ))) : []
  alb_certificate_domain = length(local.alb_cert_domains) > 0 ? local.alb_cert_domains[0] : ""
  alb_certificate_sans   = length(local.alb_cert_domains) > 1 ? slice(local.alb_cert_domains, 1, length(local.alb_cert_domains)) : []
  alb_acm_enabled        = local.use_alb && var.tls_mode == "acm" && local.alb_certificate_domain != ""
}

data "aws_route53_zone" "gdcn" {
  count   = var.dns_provider == "route53" ? 1 : 0
  zone_id = var.route53_zone_id
}

resource "aws_acm_certificate" "gdcn" {
  count = local.alb_acm_enabled ? 1 : 0

  domain_name               = local.alb_certificate_domain
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

locals {
  # Only create Route53 records when dns_provider = "route53"
  acm_route53_validation_enabled = local.alb_acm_enabled && var.dns_provider == "route53"
  route53_zone_name              = local.acm_route53_validation_enabled && length(data.aws_route53_zone.gdcn) > 0 ? trimsuffix(data.aws_route53_zone.gdcn[0].name, ".") : ""
  route53_validation_hosts       = local.acm_route53_validation_enabled ? local.alb_cert_domains : []
  invalid_route53_hosts = local.route53_zone_name != "" ? [
    for host in local.route53_validation_hosts : host
    if !(host == local.route53_zone_name || endswith(host, ".${local.route53_zone_name}"))
  ] : []
}

resource "null_resource" "validate_route53_hostnames" {
  count = local.acm_route53_validation_enabled ? 1 : 0

  lifecycle {
    precondition {
      condition     = length(local.invalid_route53_hosts) == 0
      error_message = "auth_hostname and gdcn_orgs[*].hostname must be within Route53 zone '${local.route53_zone_name}'. Invalid: ${join(", ", local.invalid_route53_hosts)}"
    }
  }
}

resource "aws_route53_record" "gdcn_acm_validation" {
  for_each = local.acm_route53_validation_enabled ? {
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

# Only validate automatically when Route53 manages DNS.
# For self-managed DNS, skip validation - the certificate will validate
# asynchronously once the user creates the DNS records shown in output.
resource "aws_acm_certificate_validation" "gdcn" {
  count = local.alb_acm_enabled && var.dns_provider == "route53" ? 1 : 0

  certificate_arn         = aws_acm_certificate.gdcn[0].arn
  validation_record_fqdns = [for record in aws_route53_record.gdcn_acm_validation : record.fqdn]
}

# For self-managed DNS, force-detach the HTTPS listener before cert replacement.
# This avoids blocking destroys of the old cert when the new cert is still pending.
resource "null_resource" "detach_alb_https_listener" {
  count = local.alb_acm_enabled && var.dns_provider == "self-managed" ? 1 : 0

  triggers = {
    cert_domains = join(",", local.alb_cert_domains)
  }

  provisioner "local-exec" {
    command = <<-EOT
      lb_arn="$(aws elbv2 describe-load-balancers \
        --names "${local.alb_load_balancer_name}" \
        --region "${var.aws_region}" \
        --profile "${var.aws_profile_name}" \
        --query "LoadBalancers[0].LoadBalancerArn" \
        --output text 2>/dev/null || echo "")"

      if [ -n "$lb_arn" ] && [ "$lb_arn" != "None" ]; then
        listener_arn="$(aws elbv2 describe-listeners \
          --load-balancer-arn "$lb_arn" \
          --region "${var.aws_region}" \
          --profile "${var.aws_profile_name}" \
          --query "Listeners[?Port==\`443\`].ListenerArn | [0]" \
          --output text 2>/dev/null || echo "")"
      else
        listener_arn=""
      fi

      if [ -n "$listener_arn" ] && [ "$listener_arn" != "None" ]; then
        aws elbv2 delete-listener \
          --listener-arn "$listener_arn" \
          --region "${var.aws_region}" \
          --profile "${var.aws_profile_name}" >/dev/null 2>&1 || true
      fi
    EOT
  }

  depends_on = [null_resource.wait_for_alb]
}

# Wait for the ALB to be created by the AWS Load Balancer Controller
resource "null_resource" "wait_for_alb" {
  count = local.use_alb ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      timeout 600 bash -c 'until aws elbv2 describe-load-balancers \
        --names ${local.alb_load_balancer_name} --region ${var.aws_region} --profile ${var.aws_profile_name} 2>/dev/null; do sleep 10; done' \
        || (echo "ERROR: ALB '${local.alb_load_balancer_name}' not created within 10 minutes. Check AWS LB Controller logs." && exit 1)
    EOT
  }

  depends_on = [module.k8s_common]
}

data "aws_lb" "gdcn" {
  count = local.use_alb ? 1 : 0

  name = local.alb_load_balancer_name

  depends_on = [null_resource.wait_for_alb]
}

# Query NLB DNS name directly from AWS (NLB name is deterministic)
data "external" "ingress_nginx_lb" {
  count = local.use_ingress_nginx ? 1 : 0

  program = [
    "bash", "-c",
    <<-EOT
      hostname=$(aws elbv2 describe-load-balancers \
        --names "${local.nlb_load_balancer_name}" \
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
