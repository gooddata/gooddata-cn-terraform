###
# Deploy all common Kubernetes resources
###

locals {
  gdcn_namespace            = "gooddata-cn"
  gdcn_service_account_name = "gooddata-cn"
  use_alb                   = var.ingress_controller == "alb"
  use_ingress_nginx         = var.ingress_controller == "ingress-nginx"
  nlb_load_balancer_name    = local.use_ingress_nginx ? "${var.deployment_name}-ingress" : ""
  alb_base_name             = "${var.deployment_name}-gdcn"
  alb_name_sanitized        = replace(lower(local.alb_base_name), "/[^a-z0-9-]/", "-")
  alb_load_balancer_name    = local.use_alb ? substr(local.alb_name_sanitized, 0, min(length(local.alb_name_sanitized), 32)) : ""
  # When Route53: use validated cert ARN; when self-managed: use cert ARN directly (pending until user validates).
  # For self-managed DNS rotations, HTTPS may be temporarily removed while the old cert is detached.
  alb_certificate_arn = local.use_alb && var.tls_mode == "acm" ? (
    length(aws_acm_certificate_validation.gdcn) > 0 ? aws_acm_certificate_validation.gdcn[0].certificate_arn : (
      length(aws_acm_certificate.gdcn) > 0 ? aws_acm_certificate.gdcn[0].arn : ""
    )
  ) : ""
  alb_tag_pairs       = [for k, v in var.aws_additional_tags : "${k}=${v}"]
  alb_tags_annotation = local.use_alb && length(local.alb_tag_pairs) > 0 ? join(",", local.alb_tag_pairs) : null
  alb_shared_annotations = local.use_alb ? merge({
    "alb.ingress.kubernetes.io/load-balancer-name"       = local.alb_load_balancer_name
    "alb.ingress.kubernetes.io/group.name"               = local.alb_load_balancer_name
    "alb.ingress.kubernetes.io/scheme"                   = "internet-facing"
    "alb.ingress.kubernetes.io/target-type"              = "ip"
    "alb.ingress.kubernetes.io/listen-ports"             = "[{\"HTTP\":80},{\"HTTPS\":443}]"
    "alb.ingress.kubernetes.io/ssl-redirect"             = "443"
    "alb.ingress.kubernetes.io/certificate-arn"          = local.alb_certificate_arn
    "alb.ingress.kubernetes.io/load-balancer-attributes" = "idle_timeout.timeout_seconds=180"
    }, local.alb_tags_annotation != null ? {
    "alb.ingress.kubernetes.io/tags" = local.alb_tags_annotation
  } : {}) : {}
}

module "k8s_common" {
  source = "../modules/k8s-common"

  providers = {
    kubernetes = kubernetes
    helm       = helm
    kubectl    = kubectl
    random     = random
    external   = external
  }

  deployment_name    = var.deployment_name
  gdcn_license_key   = var.gdcn_license_key
  gdcn_orgs          = var.gdcn_orgs
  size_profile       = var.size_profile
  cloud              = "aws"
  ingress_controller = var.ingress_controller
  gdcn_irsa_role_arn = aws_iam_role.gdcn_irsa.arn

  letsencrypt_email       = var.letsencrypt_email
  auth_hostname           = var.auth_hostname
  tls_mode                = var.tls_mode
  ingress_nginx_behind_l7 = var.ingress_nginx_behind_l7

  enable_ai_features = var.enable_ai_features
  enable_image_cache = var.enable_image_cache
  registry_dockerio  = local.registry_dockerio
  registry_quayio    = local.registry_quayio
  registry_k8sio     = local.registry_k8sio

  helm_cert_manager_version  = var.helm_cert_manager_version
  helm_gdcn_version          = var.helm_gdcn_version
  helm_pulsar_version        = var.helm_pulsar_version
  helm_ingress_nginx_version = var.helm_ingress_nginx_version

  db_hostname = module.rds_postgresql.db_instance_address
  db_username = local.db_username
  db_password = local.db_password

  # AWS-specific storage configuration
  aws_region                 = var.aws_region
  s3_quiver_cache_bucket_id  = aws_s3_bucket.buckets["quiver_cache"].id
  s3_datasource_fs_bucket_id = aws_s3_bucket.buckets["datasource_fs"].id
  s3_exports_bucket_id       = aws_s3_bucket.buckets["exports"].id

  ingress_annotations_override     = local.alb_shared_annotations
  dex_ingress_annotations_override = local.alb_shared_annotations

  depends_on = [
    module.eks,
    module.k8s_aws,
    aws_security_group_rule.rds_postgres_ingress_from_nodes,
    aws_acm_certificate_validation.gdcn,
    aws_acm_certificate.gdcn,
    aws_ecr_pull_through_cache_rule.dockerio,
    aws_ecr_pull_through_cache_rule.quayio,
    aws_ecr_pull_through_cache_rule.k8sio,
    aws_iam_role_policy_attachment.gdcn_irsa_s3_access,
    aws_secretsmanager_secret_version.dockerio,
  ]
}
