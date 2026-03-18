###
# Lake Formation S3 Tables integration for StarRocks Iceberg REST Catalog
# https://docs.aws.amazon.com/lake-formation/latest/dg/s3tables-catalog-prerequisites.html#step3-permissions
###

# Resolve the IAM role/user ARN of the Terraform caller. The STS session ARN
# returned by data.aws_caller_identity cannot be used as a LakeFormation admin
# directly; aws_iam_session_context normalises it to the underlying IAM ARN.
data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

# WARNING: allow_full_table_external_data_access applies account-wide, not per-catalog.
# If this AWS account hosts other Lake Formation data lakes, enabling this will grant
# external data access to all of them. In dedicated accounts this is safe; in shared
# accounts, review impact.
#
# admins: the Terraform caller must be a data lake administrator so that the
# local-exec provisioners below can call lakeformation grant-permissions on the
# S3 Tables federated catalog (which requires admin status).
resource "aws_lakeformation_data_lake_settings" "this" {
  count = var.enable_starrocks ? 1 : 0

  admins                                = [data.aws_iam_session_context.current.issuer_arn]
  allow_full_table_external_data_access = true
}

data "aws_iam_policy_document" "s3tables_assume_role" {
  count = var.enable_starrocks ? 1 : 0

  version = "2012-10-17"

  statement {
    sid    = "LakeFormationDataAccessPolicy"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lakeformation.amazonaws.com"]
    }

    actions = [
      "sts:AssumeRole",
      "sts:SetContext",
      "sts:SetSourceIdentity"
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

data "aws_iam_policy_document" "s3tables_data_access" {
  count = var.enable_starrocks ? 1 : 0

  version = "2012-10-17"

  statement {
    sid    = "LakeFormationPermissionsForS3ListTableBucket"
    effect = "Allow"

    actions = [
      "s3tables:ListTableBuckets"
    ]

    resources = [
      "*"
    ]
  }

  statement {
    sid    = "LakeFormationDataAccessPermissionsForS3TableBucket"
    effect = "Allow"

    actions = [
      "s3tables:CreateTableBucket",
      "s3tables:GetTableBucket",
      "s3tables:CreateNamespace",
      "s3tables:GetNamespace",
      "s3tables:ListNamespaces",
      "s3tables:DeleteNamespace",
      "s3tables:DeleteTableBucket",
      "s3tables:CreateTable",
      "s3tables:DeleteTable",
      "s3tables:GetTable",
      "s3tables:ListTables",
      "s3tables:RenameTable",
      "s3tables:UpdateTableMetadataLocation",
      "s3tables:GetTableMetadataLocation",
      "s3tables:GetTableData",
      "s3tables:PutTableData"
    ]

    resources = [
      "arn:aws:s3tables:${var.aws_region}:${data.aws_caller_identity.current.account_id}:bucket/*"
    ]
  }
}

resource "aws_iam_role" "s3tables_lakeformation" {
  count = var.enable_starrocks ? 1 : 0

  name               = "${var.deployment_name}-LakeFormationS3TablesServiceRole"
  assume_role_policy = data.aws_iam_policy_document.s3tables_assume_role[0].json

  tags = {
    Name        = "${var.deployment_name} LakeFormation S3Tables Service Role"
    Description = "IAM service role for LakeFormation to access S3Tables resources in ${var.aws_region}"
  }
}

resource "aws_iam_role_policy" "s3tables_lakeformation" {
  count = var.enable_starrocks ? 1 : 0

  name_prefix = "S3TablesPolicyForLakeFormation-"
  role        = aws_iam_role.s3tables_lakeformation[0].id
  policy      = data.aws_iam_policy_document.s3tables_data_access[0].json
}

resource "aws_lakeformation_resource" "s3tables" {
  count = var.enable_starrocks ? 1 : 0

  arn                    = "arn:aws:s3tables:${var.aws_region}:${data.aws_caller_identity.current.account_id}:bucket/*"
  role_arn               = aws_iam_role.s3tables_lakeformation[0].arn
  with_federation        = true
  with_privileged_access = true

  depends_on = [aws_iam_role_policy.s3tables_lakeformation]
}

# Workaround: Use AWS CLI to create Glue catalog until Terraform supports it
# https://github.com/hashicorp/terraform-provider-aws/issues/43340
resource "terraform_data" "s3tables_glue_catalog" {
  count = var.enable_starrocks ? 1 : 0

  # Store values needed for destroy-time provisioner
  input = {
    catalog_name = "s3tablescatalog"
    resource_arn = aws_lakeformation_resource.s3tables[0].arn
    region       = var.aws_region
    profile      = var.aws_profile_name
  }

  # Create the Glue catalog using AWS CLI
  provisioner "local-exec" {
    command = <<-EOF
      if ! aws glue create-catalog \
        --name "${self.input.catalog_name}" \
        --catalog-input '{
          "FederatedCatalog": {
            "Identifier": "${self.input.resource_arn}",
            "ConnectionName": "aws:s3tables"
          },
          "CreateDatabaseDefaultPermissions": [],
          "CreateTableDefaultPermissions": []
        }' \
        --profile ${self.input.profile} \
        --region ${self.input.region} 2>&1; then
        echo "create-catalog failed (may already exist), continuing."
      fi
    EOF
  }

  # Clean up on destroy — fail loudly unless the catalog is already gone
  provisioner "local-exec" {
    when    = destroy
    command = <<-EOF
      aws glue get-catalog --catalog-id "${self.input.catalog_name}" \
        --profile ${self.input.profile} \
        --region ${self.input.region} 2>/dev/null \
        || { echo "Catalog does not exist, skipping."; exit 0; }
      aws glue delete-catalog \
        --catalog-id "${self.input.catalog_name}" \
        --profile ${self.input.profile} \
        --region ${self.input.region}
    EOF
  }

  depends_on = [aws_lakeformation_data_lake_settings.this]
}

# Workaround: Grant Lake Formation permissions on the S3 Tables catalog until
# hashicorp/terraform-provider-aws#46233 adds catalog_resource_id support to
# aws_lakeformation_permissions.
resource "terraform_data" "s3tables_lakeformation_permissions" {
  count = var.enable_starrocks ? 1 : 0

  input = {
    principal_arn       = aws_iam_user.starrocks_s3_tables[0].arn
    catalog_resource_id = "${local.s3tables_catalog_id}/${aws_s3tables_table_bucket.starrocks_tables[0].name}"
    catalog_name        = "s3tablescatalog"
    database_name       = replace(var.deployment_name, "-", "_")
    region              = var.aws_region
    profile             = var.aws_profile_name
  }

  # Grant catalog-level permissions (Resource.Catalog.Id)
  provisioner "local-exec" {
    command = <<-EOF
      aws lakeformation grant-permissions \
        --principal '{"DataLakePrincipalIdentifier":"${self.input.principal_arn}"}' \
        --resource '{"Catalog":{"Id":"${self.input.catalog_resource_id}"}}' \
        --permissions ALL \
        --profile ${self.input.profile} \
        --region ${self.input.region}
    EOF
  }

  # Grant database-level permissions
  provisioner "local-exec" {
    command = <<-EOF
      aws lakeformation grant-permissions \
        --principal '{"DataLakePrincipalIdentifier":"${self.input.principal_arn}"}' \
        --resource '{"Database":{"CatalogId":"${self.input.catalog_resource_id}","Name":"${self.input.database_name}"}}' \
        --permissions ALL \
        --profile ${self.input.profile} \
        --region ${self.input.region}
    EOF
  }

  # Grant table-level permissions (wildcard = all tables)
  provisioner "local-exec" {
    command = <<-EOF
      aws lakeformation grant-permissions \
        --principal '{"DataLakePrincipalIdentifier":"${self.input.principal_arn}"}' \
        --resource '{"Table":{"CatalogId":"${self.input.catalog_resource_id}","DatabaseName":"${self.input.database_name}","TableWildcard":{}}}' \
        --permissions ALL \
        --profile ${self.input.profile} \
        --region ${self.input.region}
    EOF
  }

  # Revoke on destroy — skip if the catalog is already gone (permissions go with it).
  # Individual revokes use || true so a "permission not found" error (e.g. from a
  # partially-applied grant) does not block destroy.
  provisioner "local-exec" {
    when    = destroy
    command = <<-EOF
      aws glue get-catalog --catalog-id "${self.input.catalog_name}" \
        --profile ${self.input.profile} \
        --region ${self.input.region} 2>/dev/null \
        || { echo "Catalog does not exist, permissions already gone."; exit 0; }
      aws lakeformation revoke-permissions \
        --principal '{"DataLakePrincipalIdentifier":"${self.input.principal_arn}"}' \
        --resource '{"Catalog":{"Id":"${self.input.catalog_resource_id}"}}' \
        --permissions ALL \
        --profile ${self.input.profile} \
        --region ${self.input.region} \
        || echo "Catalog-level revoke skipped (permission may not exist)."
      aws lakeformation revoke-permissions \
        --principal '{"DataLakePrincipalIdentifier":"${self.input.principal_arn}"}' \
        --resource '{"Database":{"CatalogId":"${self.input.catalog_resource_id}","Name":"${self.input.database_name}"}}' \
        --permissions ALL \
        --profile ${self.input.profile} \
        --region ${self.input.region} \
        || echo "Database-level revoke skipped (permission may not exist)."
      aws lakeformation revoke-permissions \
        --principal '{"DataLakePrincipalIdentifier":"${self.input.principal_arn}"}' \
        --resource '{"Table":{"CatalogId":"${self.input.catalog_resource_id}","DatabaseName":"${self.input.database_name}","TableWildcard":{}}}' \
        --permissions ALL \
        --profile ${self.input.profile} \
        --region ${self.input.region} \
        || echo "Table-level revoke skipped (permission may not exist)."
    EOF
  }

  depends_on = [
    aws_lakeformation_data_lake_settings.this,
    terraform_data.s3tables_glue_catalog,
    aws_s3tables_namespace.starrocks_tables,
  ]
}
