###
# IAM role for GoodData.CN service account (IRSA)
###

data "aws_iam_policy_document" "gdcn_irsa_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values = [
        "system:serviceaccount:${var.gdcn_namespace}:${local.gdcn_service_account_name}"
      ]
    }
  }
}

resource "aws_iam_role" "gdcn_irsa" {
  name               = "${var.deployment_name}-gdcn-irsa"
  assume_role_policy = data.aws_iam_policy_document.gdcn_irsa_assume_role.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "gdcn_irsa_s3_access" {
  role       = aws_iam_role.gdcn_irsa.name
  policy_arn = aws_iam_policy.gdcn_s3_access.arn
}

###
# IAM role for StarRocks service account (IRSA)
###

data "aws_iam_policy_document" "starrocks_irsa_assume_role" {
  count = var.enable_ai_lake ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values = [
        "system:serviceaccount:starrocks:starrocks"
      ]
    }
  }
}

resource "aws_iam_role" "starrocks_irsa" {
  count = var.enable_ai_lake ? 1 : 0

  name               = "${var.deployment_name}-starrocks-irsa"
  assume_role_policy = data.aws_iam_policy_document.starrocks_irsa_assume_role[0].json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "starrocks_irsa_s3_access" {
  count = var.enable_ai_lake ? 1 : 0

  role       = aws_iam_role.starrocks_irsa[0].name
  policy_arn = aws_iam_policy.starrocks_s3_access[0].arn
}

###
# IAM role for AI Lake service account (EKS Pod Identity)
###

data "aws_iam_policy_document" "ai_lake_pod_identity_assume_role" {
  count = var.enable_ai_lake ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "ai_lake_pod_identity_access" {
  count = var.enable_ai_lake ? 1 : 0

  statement {
    sid    = "AssumeS3TablesAilakeBucketRoles"
    effect = "Allow"
    actions = [
      "sts:AssumeRole",
      "sts:TagSession",
    ]
    resources = [
      aws_iam_role.s3tables_ailake[0].arn,
    ]
  }
}

resource "aws_iam_role" "ai_lake_pod_identity" {
  count = var.enable_ai_lake ? 1 : 0

  name               = "${var.deployment_name}-ai-lake"
  assume_role_policy = data.aws_iam_policy_document.ai_lake_pod_identity_assume_role[0].json
  tags               = local.common_tags
}

resource "aws_iam_role_policy" "ai_lake_pod_identity" {
  count = var.enable_ai_lake ? 1 : 0

  name   = "${var.deployment_name}-AILakePodIdentityAccess"
  role   = aws_iam_role.ai_lake_pod_identity[0].id
  policy = data.aws_iam_policy_document.ai_lake_pod_identity_access[0].json
}

