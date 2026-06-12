# S3 model cache for the inference GPU pool (SIE clusterCache / vLLM).
# Survives scale-to-zero of the GPU node so model weights are not re-downloaded
# from Hugging Face on every cold start. Private, encrypted, destroyed with the env.

resource "aws_s3_bucket" "model_cache" {
  count = var.enable_inference_gpu_pool ? 1 : 0

  bucket        = "${var.deployment_name}-model-cache-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = local.common_tags
}

resource "aws_s3_bucket_public_access_block" "model_cache" {
  count = var.enable_inference_gpu_pool ? 1 : 0

  bucket                  = aws_s3_bucket.model_cache[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "model_cache" {
  count = var.enable_inference_gpu_pool ? 1 : 0

  bucket = aws_s3_bucket.model_cache[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Read/write for inference workers. Attached to the GPU node group role
# (node-level credentials — no IRSA needed for the third-party charts).
resource "aws_iam_policy" "model_cache_access" {
  count = var.enable_inference_gpu_pool ? 1 : 0

  name = "${var.deployment_name}-model-cache-access"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.model_cache[0].arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.model_cache[0].arn}/*"
      }
    ]
  })

  tags = local.common_tags
}

output "model_cache_bucket_url" {
  value = var.enable_inference_gpu_pool ? "s3://${aws_s3_bucket.model_cache[0].bucket}/models" : null
}
