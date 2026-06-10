# CLAUDE.md

CLAUDE.md is the source of truth for repo conventions. This repo is primarily authored against Claude Code, but any capable coding agent can drive it; [`AGENTS.md`](AGENTS.md) points here.

## Terraform workflow

### Never run `terraform apply -auto-approve`

Always let the user review and approve applies themselves. You may run `terraform plan` freely.

### After making changes to `.tf` or `.tfvars` files

1. Run `terraform fmt -recursive` from the project root — treat this as the lint step and let it auto-fix style issues. Re-run until it produces no diff.
2. Run `terraform validate` in the relevant directory to verify the configuration is consistent.
3. Fix any issues fmt or validate uncover before proceeding. If an issue cannot be auto-corrected, call it out explicitly so it can be resolved manually.

### Validating across environments

When a change affects shared modules, run `terraform plan -var-file=settings.tfvars` in all three environment directories (aws, azure, local) to catch environment-specific issues.

AWS and Azure may not have active clusters, so plan errors from missing state or credentials are expected. Focus on catching Terraform configuration errors (missing variables, type mismatches, invalid references).

## Commit messages

Follow Conventional Commits: `<type>[optional scope]: <description>` (e.g., `feat(observability): add Grafana Dex SSO`).

- Common types: `feat`, `fix`, `docs`, `chore`, `refactor`, `perf`, `test`, `build`, `ci`.
- Mark breaking changes with `!` after the type/scope or add a `BREAKING CHANGE:` footer.
- Keep descriptions concise and lowercase; add a body/footer when extra context is needed.
