# Project Norms

## Terraform workflow

### Never run `terraform apply -auto-approve`

Always let the user review and approve applies themselves. You may run `terraform plan` freely.

### After making changes to `.tf` or `.tfvars` files

1. Run `terraform fmt -recursive` from the project root — re-run until no diff.
2. Run `terraform validate` in the relevant directory.
3. Fix any issues before proceeding.

### Validating across environments

When a change affects shared modules, run `terraform plan -var-file=settings.tfvars` in all three environment directories (aws, azure, local) to catch environment-specific issues.

AWS and Azure may not have active clusters, so plan errors from missing state or credentials are expected. Focus on catching Terraform configuration errors (missing variables, type mismatches, invalid references).

## Commit messages

Follow Conventional Commits: `<type>[optional scope]: <description>` (e.g., `feat(observability): add Grafana Dex SSO`).
