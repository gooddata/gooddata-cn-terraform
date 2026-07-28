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
      variable = local.eks_oidc_condition_key
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
# IAM role for the EBS CSI driver (IRSA)
###

# Without this the driver falls back to IMDS, which pods cannot reach at the
# default hop limit of 1.
data "aws_iam_policy_document" "ebs_csi_irsa_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = local.eks_oidc_condition_key
      values = [
        "system:serviceaccount:kube-system:ebs-csi-controller-sa"
      ]
    }
  }
}

resource "aws_iam_role" "ebs_csi_irsa" {
  name               = "${var.deployment_name}-ebs-csi-irsa"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_irsa_assume_role.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi_irsa" {
  role       = aws_iam_role.ebs_csi_irsa.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

###
# IAM role for observability (Loki + Tempo) service accounts (IRSA)
###

# One role assumed by both the loki and tempo service accounts in the
# observability namespace. The EKS IRSA webhook injects the web-identity token
# off the SA's eks.amazonaws.com/role-arn annotation (no pod label needed).
data "aws_iam_policy_document" "observability_irsa_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = local.eks_oidc_condition_key
      values = [
        "system:serviceaccount:observability:loki",
        "system:serviceaccount:observability:tempo",
      ]
    }
  }
}

resource "aws_iam_role" "observability_irsa" {
  name               = "${var.deployment_name}-observability-irsa"
  assume_role_policy = data.aws_iam_policy_document.observability_irsa_assume_role.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "observability_irsa_s3_access" {
  role       = aws_iam_role.observability_irsa.name
  policy_arn = aws_iam_policy.observability_s3_access.arn
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
      variable = local.eks_oidc_condition_key
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

