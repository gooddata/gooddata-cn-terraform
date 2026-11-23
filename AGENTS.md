# AGENTS.md

Terraform for deploying GoodData.CN on AWS, Azure, and local (k3d) environments.

## Terraform workflow

- After editing `.tf` or `.tfvars` files:
  1. Run `terraform fmt -recursive` from the repo root until it produces no diff.
  2. Run `terraform validate` in each affected environment directory.
  3. Fix any errors. If an error cannot be fixed automatically, report it.
- When a change touches a shared module, run `terraform plan -var-file=settings.tfvars` in `aws/`, `azure/`, and `local/`. Errors from missing state or credentials are expected when no cluster exists; look only for configuration errors (missing variables, type mismatches, invalid references).

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/): `<type>(<scope>): <description>`, for example `feat(observability): add Grafana Dex SSO`.

- Types: `feat`, `fix`, `docs`, `chore`, `refactor`, `perf`, `test`, `build`, `ci`.
- Mark breaking changes with `!` after the type/scope or a `BREAKING CHANGE:` footer.
- Keep the description short and lowercase. Add a body when more context is needed.
