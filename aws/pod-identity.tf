###
# EKS Pod Identity associations
###

resource "aws_eks_pod_identity_association" "ai_lake" {
  count = var.enable_ai_lake ? 1 : 0

  cluster_name    = module.eks.cluster_name
  namespace       = "gooddata-cn"
  service_account = "gooddata-cn-ailake"
  role_arn        = aws_iam_role.ai_lake_pod_identity[0].arn

  depends_on = [
    aws_iam_role_policy.ai_lake_pod_identity,
  ]
}
