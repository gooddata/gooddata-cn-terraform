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

  tags = local.common_tags
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

  # Shared ARN fragments for StarRocks Glue/S3 Tables policies
  glue_arn_prefix     = "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}"
  s3tables_catalog_id = "${data.aws_caller_identity.current.account_id}:s3tablescatalog"
}

###
# StarRocks S3 bucket (conditional)
###

resource "aws_s3_bucket" "starrocks" {
  count = var.enable_starrocks ? 1 : 0

  bucket        = substr("${local.bucket_prefix}-starrocks", 0, 63)
  force_destroy = true

  tags = local.common_tags
}

resource "aws_s3_bucket_public_access_block" "starrocks" {
  count  = var.enable_starrocks ? 1 : 0
  bucket = aws_s3_bucket.starrocks[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "starrocks" {
  count  = var.enable_starrocks ? 1 : 0
  bucket = aws_s3_bucket.starrocks[0].id

  versioning_configuration {
    status = "Suspended"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "starrocks" {
  count  = var.enable_starrocks ? 1 : 0
  bucket = aws_s3_bucket.starrocks[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_iam_policy" "starrocks_s3_access" {
  count = var.enable_starrocks ? 1 : 0

  name        = "${var.deployment_name}-StarRocksS3Access"
  description = "Allow StarRocks workloads to use S3 bucket for shared-data storage."

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
        Resource = [aws_s3_bucket.starrocks[0].arn]
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
        Resource = ["${aws_s3_bucket.starrocks[0].arn}/*"]
      }
    ]
  })
}

###
# StarRocks S3 Table Bucket for Iceberg REST Catalog (conditional)
###

resource "aws_s3tables_table_bucket" "starrocks_tables" {
  count = var.enable_starrocks ? 1 : 0
  name  = "${var.deployment_name}-starrocks-tables"
}

resource "aws_s3tables_namespace" "starrocks_tables" {
  count            = var.enable_starrocks ? 1 : 0
  namespace        = replace(var.deployment_name, "-", "_")
  table_bucket_arn = aws_s3tables_table_bucket.starrocks_tables[0].arn
}

# Delete all tables in the S3 Tables namespace before destroying the namespace
# itself. StarRocks creates tables at runtime that Terraform doesn't manage, so
# the namespace would otherwise fail to delete with "not empty" error.
resource "terraform_data" "starrocks_tables_cleanup" {
  count = var.enable_starrocks ? 1 : 0

  input = {
    table_bucket_arn = aws_s3tables_table_bucket.starrocks_tables[0].arn
    namespace        = aws_s3tables_namespace.starrocks_tables[0].namespace
    region           = var.aws_region
    profile          = var.aws_profile_name
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOF
      aws s3tables list-namespaces \
        --table-bucket-arn "${self.input.table_bucket_arn}" \
        --profile ${self.input.profile} \
        --region ${self.input.region} 2>/dev/null \
        || { echo "Table bucket does not exist, skipping cleanup."; exit 0; }
      for table in $(aws s3tables list-tables \
        --table-bucket-arn "${self.input.table_bucket_arn}" \
        --namespace "${self.input.namespace}" \
        --query 'tables[].name' --output text \
        --profile ${self.input.profile} \
        --region ${self.input.region}); do
        echo "Deleting table: $table"
        aws s3tables delete-table \
          --table-bucket-arn "${self.input.table_bucket_arn}" \
          --namespace "${self.input.namespace}" \
          --name "$table" \
          --profile ${self.input.profile} \
          --region ${self.input.region}
      done
    EOF
  }
}

# StarRocks's Iceberg REST catalog connector requires explicit access-key-id and
# secret-access-key properties. IRSA (STS) cannot be used because the Glue REST
# endpoint requires SigV4 signing with static credentials, not role-based auth.
resource "aws_iam_user" "starrocks_s3_tables" {
  count = var.enable_starrocks ? 1 : 0
  name  = "${var.deployment_name}-starrocks-s3-tables"
  tags  = local.common_tags
}

resource "aws_iam_policy" "starrocks_s3_tables_access" {
  count = var.enable_starrocks ? 1 : 0

  name        = "${var.deployment_name}-StarRocksS3TablesAccess"
  description = "Allow StarRocks Iceberg REST catalog to access S3 Table Bucket via Glue and Lake Formation."

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid    = "AllowGlueCatalogAccess",
        Effect = "Allow",
        Action = [
          "glue:GetCatalog",
          "glue:GetDatabase",
          "glue:GetDatabases",
          "glue:GetTable",
          "glue:GetTables",
          "glue:CreateTable",
          "glue:UpdateTable",
          "glue:GetPartition",
          "glue:GetPartitions",
          "glue:BatchCreatePartition",
          "glue:BatchUpdatePartition"
        ],
        Resource = [
          "${local.glue_arn_prefix}:catalog",
          "${local.glue_arn_prefix}:catalog/s3tablescatalog",
          "${local.glue_arn_prefix}:catalog/s3tablescatalog/*",
          "${local.glue_arn_prefix}:database/s3tablescatalog/*",
          "${local.glue_arn_prefix}:table/s3tablescatalog/*",
        ]
      },
      {
        Sid      = "AllowLakeFormationDataAccess",
        Effect   = "Allow",
        Action   = ["lakeformation:GetDataAccess"],
        Resource = ["*"]
      }
    ]
  })
}

resource "aws_iam_user_policy_attachment" "starrocks_s3_tables" {
  count      = var.enable_starrocks ? 1 : 0
  user       = aws_iam_user.starrocks_s3_tables[0].name
  policy_arn = aws_iam_policy.starrocks_s3_tables_access[0].arn
}

resource "aws_iam_access_key" "starrocks_s3_tables" {
  count = var.enable_starrocks ? 1 : 0
  user  = aws_iam_user.starrocks_s3_tables[0].name
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
