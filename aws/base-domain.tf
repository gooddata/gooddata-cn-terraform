// Optional lookup of the Route53 zone so we can pull its normalized name.
data "aws_route53_zone" "gooddata" {
  count   = trimspace(var.route53_zone_id) != "" ? 1 : 0
  zone_id = var.route53_zone_id
}

locals {
  // Strip the /hostedzone/ prefix that AWS sometimes adds to IDs.
  cleaned_route53_zone_id = trimspace(replace(var.route53_zone_id, "/hostedzone/", ""))

  // If we fetched the zone, use its name without the trailing dot; otherwise stay empty.
  route53_zone_name = length(data.aws_route53_zone.gooddata) > 0 ? trimsuffix(data.aws_route53_zone.gooddata[0].name, ".") : ""

  // Caller-provided base domain takes priority when present.
  base_domain_input = trimspace(var.base_domain)

  // When running ingress-nginx we might expose the LB via an Elastic IP.
  ingress_primary_eip = (var.ingress_controller == "ingress-nginx" && length(aws_eip.lb) > 0) ? aws_eip.lb[0].public_ip : ""

  // For wildcard DNS providers (like nip.io) build <deployment>.<EIP>.<provider>.
  ingress_wildcard_domain = (
    var.ingress_controller == "ingress-nginx" &&
    local.ingress_primary_eip != "" &&
    var.wildcard_dns_provider != ""
  ) ? "${var.deployment_name}.${local.ingress_primary_eip}.${var.wildcard_dns_provider}" : ""

  // Pick the best base domain:
  // 1) explicit input, 2) ALB + Route53 zone, 3) wildcard
  derived_base_domain = local.base_domain_input != "" ? local.base_domain_input : (
    var.ingress_controller == "alb" && local.route53_zone_name != "" ? "${var.deployment_name}.${local.route53_zone_name}" : local.ingress_wildcard_domain
  )

  base_domain = trimspace(local.derived_base_domain)

  // Default auth/org hosts piggyback on the base domain. If we still don't have
  // one, reuse the ingress-nginx wildcard pattern so TLS + callbacks still work.
  default_auth_domain = local.base_domain != "" ? "auth.${local.base_domain}" : (
    var.ingress_controller == "ingress-nginx" && local.ingress_primary_eip != "" && var.wildcard_dns_provider != "" ? "auth.${local.ingress_primary_eip}.${var.wildcard_dns_provider}" : ""
  )

  default_org_domain = local.base_domain != "" ? "org.${local.base_domain}" : (
    var.ingress_controller == "ingress-nginx" && local.ingress_primary_eip != "" && var.wildcard_dns_provider != "" ? "org.${local.ingress_primary_eip}.${var.wildcard_dns_provider}" : ""
  )
}

