###
# Provision S3 buckets
###

# Create S3 buckets for GoodData.CN.
# These buckets store:
# - quiver-cache: Query acceleration cache
# - quiver-datasource-fs: Data source files (e.g., uploaded CSVs)
# - exports: Exported reports or data

# Ensure the name is lower-case and contains no spaces or invalid chars
resource "random_id" "s3_suffix" {
  byte_length = 3
}

locals {
  # Sanitize cluster_name and append a random 6-character
  # suffix for bucket names to make them globally unique
  bucket_prefix = format(
    "%s-%s",
    var.deployment_name,
    random_id.s3_suffix.hex
  )

  s3_buckets = {
    quiver_cache  = "-quiver-cache"
    datasource_fs = "-quiver-datasource-fs"
    exports       = "-exports"
  }
}

resource "aws_s3_bucket" "buckets" {
  for_each      = local.s3_buckets
  bucket        = substr("${local.bucket_prefix}${each.value}", 0, 63)
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "buckets" {
  for_each = aws_s3_bucket.buckets
  bucket   = each.value.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "buckets" {
  for_each = aws_s3_bucket.buckets
  bucket   = each.value.id

  versioning_configuration {
    status = "Suspended"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "buckets" {
  for_each = aws_s3_bucket.buckets
  bucket   = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# IAM policy granting GoodData.CN access to the three S3 buckets
locals {
  # Bucket ARNs derived from the S3 bucket map
  gdcn_s3_bucket_arns = [for k in keys(local.s3_buckets) : aws_s3_bucket.buckets[k].arn]

  # Object ARNs (/* appended) for object-level permissions
  gdcn_s3_object_arns = formatlist("%s/*", local.gdcn_s3_bucket_arns)
}

resource "aws_iam_policy" "gdcn_s3_access" {
  name        = "${var.deployment_name}-GoodDataCNS3Access"
  description = "Allow GoodData.CN workloads to use S3 buckets for quiver cache, datasource FS, and exports."

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid    = "AllowBucketListingAndLocation",
        Effect = "Allow",
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:ListBucketMultipartUploads"
        ],
        Resource = local.gdcn_s3_bucket_arns
      },
      {
        Sid    = "AllowObjectReadWriteAndMultipart",
        Effect = "Allow",
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts"
        ],
        Resource = local.gdcn_s3_object_arns
      }
    ]
  })
}
