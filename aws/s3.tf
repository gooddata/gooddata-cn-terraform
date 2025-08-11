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
    replace(lower(var.deployment_name), "[^0-9a-z-]", "-"),
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
    status = "Enabled"
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
