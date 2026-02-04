###
# Deploy ExternalDNS (optional)
###

locals {
  external_dns_enabled      = var.dns_provider == "route53"
  external_dns_namespace    = "external-dns"
  external_dns_txt_owner_id = trimspace(var.deployment_name)
}

data "aws_route53_zone" "external_dns" {
  count   = local.external_dns_enabled ? 1 : 0
  zone_id = var.route53_zone_id
}

locals {
  external_dns_zone_name = local.external_dns_enabled && length(data.aws_route53_zone.external_dns) > 0 ? replace(data.aws_route53_zone.external_dns[0].name, "/\\.$/", "") : ""
  external_dns_domains   = local.external_dns_enabled && local.external_dns_zone_name != "" ? [local.external_dns_zone_name] : []
}

resource "kubernetes_namespace" "external_dns" {
  count = local.external_dns_enabled ? 1 : 0

  metadata {
    name = local.external_dns_namespace
  }
}

data "aws_iam_policy_document" "external_dns_assume_role" {
  count = local.external_dns_enabled ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.eks_cluster_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.eks_cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:${local.external_dns_namespace}:external-dns"]
    }
  }
}

data "aws_iam_policy_document" "external_dns_policy" {
  count = local.external_dns_enabled ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "route53:ChangeResourceRecordSets"
    ]
    resources = ["arn:aws:route53:::hostedzone/${var.route53_zone_id}"]
  }

  statement {
    effect = "Allow"
    actions = [
      "route53:ListHostedZones",
      "route53:ListHostedZonesByName",
      "route53:ListResourceRecordSets"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "external_dns" {
  count              = local.external_dns_enabled ? 1 : 0
  name               = "${var.deployment_name}-external-dns"
  assume_role_policy = data.aws_iam_policy_document.external_dns_assume_role[0].json
}

resource "aws_iam_policy" "external_dns" {
  count  = local.external_dns_enabled ? 1 : 0
  name   = "${var.deployment_name}-ExternalDNSPolicy"
  policy = data.aws_iam_policy_document.external_dns_policy[0].json
}

resource "aws_iam_role_policy_attachment" "external_dns" {
  count      = local.external_dns_enabled ? 1 : 0
  role       = aws_iam_role.external_dns[0].name
  policy_arn = aws_iam_policy.external_dns[0].arn
}

resource "kubernetes_service_account" "external_dns" {
  count = local.external_dns_enabled ? 1 : 0

  metadata {
    name      = "external-dns"
    namespace = kubernetes_namespace.external_dns[0].metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.external_dns[0].arn
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.external_dns,
  ]
}

resource "helm_release" "external_dns" {
  count         = local.external_dns_enabled ? 1 : 0
  name          = "external-dns"
  repository    = "https://kubernetes-sigs.github.io/external-dns/"
  chart         = "external-dns"
  version       = var.helm_external_dns_version
  namespace     = kubernetes_namespace.external_dns[0].metadata[0].name
  wait          = true
  wait_for_jobs = true
  timeout       = 1800

  values = [yamlencode({
    provider      = "aws"
    policy        = "sync"
    registry      = "txt"
    txtOwnerId    = local.external_dns_txt_owner_id
    txtPrefix     = "gdcn-"
    domainFilters = local.external_dns_domains
    zoneIdFilters = trimspace(var.route53_zone_id) != "" ? [trimspace(var.route53_zone_id)] : []
    sources       = var.ingress_controller == "istio_gateway" ? ["service"] : ["ingress"]
    serviceAccount = {
      create = false
      name   = kubernetes_service_account.external_dns[0].metadata[0].name
    }
    extraArgs = var.ingress_controller == "alb" ? [
      "--aws-prefer-cname"
    ] : []
  })]

}

