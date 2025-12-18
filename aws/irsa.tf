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
        "system:serviceaccount:${local.gdcn_namespace}:${local.gdcn_service_account_name}"
      ]
    }
  }
}

resource "aws_iam_role" "gdcn_irsa" {
  name               = "${var.deployment_name}-gdcn-irsa"
  assume_role_policy = data.aws_iam_policy_document.gdcn_irsa_assume_role.json

  tags = local.common_tags

  depends_on = [
    module.eks
  ]
}

resource "aws_iam_role_policy_attachment" "gdcn_irsa_s3_access" {
  role       = aws_iam_role.gdcn_irsa.name
  policy_arn = aws_iam_policy.gdcn_s3_access.arn
}

