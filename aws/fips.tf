###
# FIPS mode (var.fips_enabled): shared locals and Bottlerocket FIPS AMI lookup
###

locals {
  # Bottlerocket SSM paths and EKS AMI types spell the architecture differently.
  bottlerocket_ssm_arch = var.eks_node_arch == "arm64" ? "arm64" : "x86_64"
  eks_ami_type          = "${var.eks_node_arch == "arm64" ? "BOTTLEROCKET_ARM_64" : "BOTTLEROCKET_x86_64"}${var.fips_enabled ? "_FIPS" : ""}"

  # Makes in-cluster AWS SDK clients use FIPS endpoints.
  aws_fips_env = [{ name = "AWS_USE_FIPS_ENDPOINT", value = "true" }]

  # Object-storage endpoint rule (one rule for every S3 client in the cluster):
  # - s3_endpoint set: every S3 client uses it as it is, and gets no AWS_USE_FIPS_ENDPOINT (the AWS SDKs refuse a
  #   custom endpoint together with it). The user gives the FIPS host when FIPS is needed.
  # - s3_endpoint empty: no endpoint for the AWS SDK clients; under fips_enabled AWS_USE_FIPS_ENDPOINT makes them
  #   select s3-fips.<region> and sts-fips.<region>. Tempo (minio-go) does not read the variable and always needs a
  #   host: s3_host below.
  s3_endpoint_url    = var.s3_endpoint == "" ? "" : (can(regex("^https?://", var.s3_endpoint)) ? trimsuffix(var.s3_endpoint, "/") : "https://${trimsuffix(var.s3_endpoint, "/")}")
  s3_endpoint_host   = replace(local.s3_endpoint_url, "/^https?:///", "")
  s3_endpoint_is_set = var.s3_endpoint != ""
  # AWS_USE_FIPS_ENDPOINT for the S3 clients in the cluster (GoodData.CN chart value global.aws.useFipsEndpoint, Loki).
  s3_sdk_fips = var.fips_enabled && !local.s3_endpoint_is_set

  # S3 host of Tempo (and of the exports URL): the explicit endpoint, else the FIPS host under fips_enabled.
  # Path-style and virtual-hosted style both work with it; dualstack (s3-fips.dualstack.<region>) is not used.
  s3_host = local.s3_endpoint_is_set ? local.s3_endpoint_host : "s3${var.fips_enabled ? "-fips" : ""}.${var.aws_region}.amazonaws.com"

  # Loki and Tempo also read AWS_USE_FIPS_ENDPOINT for the IRSA token exchange (STS) and the S3 client.
  obs_fips_env = var.fips_enabled ? concat(local.s3_sdk_fips ? local.aws_fips_env : [], [{ name = "AWS_STS_REGIONAL_ENDPOINTS", value = "regional" }]) : []
}

# The alias bottlerocket@latest has no FIPS variant, so resolve the AMI ID.
data "aws_ssm_parameter" "bottlerocket_fips" {
  count = var.fips_enabled && var.karpenter_fips_ami_id == "" ? 1 : 0

  name = "/aws/service/bottlerocket/aws-k8s-${var.eks_version}-fips/${local.bottlerocket_ssm_arch}/latest/image_id"
}

locals {
  karpenter_ami_selector_terms = var.fips_enabled ? [{ id = var.karpenter_fips_ami_id != "" ? var.karpenter_fips_ami_id : nonsensitive(data.aws_ssm_parameter.bottlerocket_fips[0].value) }] : [{ alias = "bottlerocket@latest" }]
}
