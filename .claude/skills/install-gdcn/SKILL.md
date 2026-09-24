---
name: install-gdcn
description: Guide a first GoodData.CN deployment with this repo's Terraform on AWS, Azure, or a local k3d cluster - check CLI prerequisites, scaffold settings.tfvars from the example without inventing values, run plan and apply with an explicit confirmation before every apply, configure kubectl, and verify pods, organizations, DNS, and login. Use whenever the user wants to install, deploy, spin up, stand up, evaluate, or try out GoodData.CN, asks where to start with this repo, has a fresh clone and a license key, wants a local, k3d, or laptop deployment, asks which settings.tfvars values are required, or hits a first-apply error such as "connection refused" from the Kubernetes provider on local or a missing aws_profile_name. Not for upgrading a running deployment (use upgrade-gdcn) or diagnosing one that already exists (use troubleshoot-gdcn).
---

# Install GoodData.CN with this repo

This repo deploys GoodData.CN for evaluation, not production, on AWS (EKS), Azure
(AKS), or a local k3d cluster. This skill walks a first deployment from an empty
`settings.tfvars` to a working login, with a checkpoint before every change.
The user keeps control of every apply and never has to paste a secret into the
conversation.

## Rules

- **Read freely, change only with a yes.** `terraform plan`, `terraform output`,
  `terraform fmt -check`, `kubectl get`, `kubectl describe`, `kubectl logs`,
  `kubectl top`, `helm list`, `helm history`, `helm status`, and `git diff` run
  without asking. Anything that changes files, Terraform state, or the cluster is
  listed first, with the exact command, and runs only after the user answers yes.
  This covers creating or editing `settings.tfvars`, every `terraform apply`,
  every `kubectl` verb other than get, describe, logs, and top, and every script
  under `scripts/` that talks to a cloud API.
- **Applies use a saved plan.** Run
  `terraform plan -var-file=settings.tfvars -out=tfplan`, summarize what changes,
  wait for a yes, run `terraform apply tfplan`, then `rm tfplan`. The plan file
  embeds variable values, including the license key. Never `-auto-approve`, and
  never answer Terraform's own confirmation prompt on the user's behalf.
- **Secrets stay out of the conversation.** Refer to `gdcn_license_key`, Docker
  Hub tokens, subscription IDs, and the contents of `gdcn-license`,
  `gdcn-org-admin-<id>`, and Grafana admin secrets by name only. Check that a
  secret exists with `kubectl get secret <name> -n gooddata-cn`, never with
  `-o yaml`. Never `cat` a tfvars file into the conversation and never run
  `terraform output -json` without a specific output name.
- **Never invent a value.** When a required variable has no obvious value, ask.
  Optional knobs stay exactly as the example ships them, commented placeholders
  included.
- **An existing `settings.tfvars` means this is not a first install.** Run the
  `sync-settings-tfvars` skill through the Skill tool to bring the file up to
  date, then continue from step 4.
- **Interactive commands belong to the user.** `aws sso login`, `az login`, and
  `scripts/create-user.sh` prompt on the terminal, so ask the user to run them
  and verify the result afterwards with a read-only command.
- **Other skills are called by name** through the Skill tool. Never read their
  files by path or restate their procedures.

## Step 1: pick the target

Ask which environment the user wants, unless they already said:

| Situation | Environment | Reference |
| --- | --- | --- |
| Laptop, no cloud account, quick look | `local` | `references/local.md` |
| AWS account and an IAM or SSO profile | `aws` | `references/aws.md` |
| Azure subscription | `azure` | `references/azure.md` |

Read the matching reference in full before going on. It lists the required
values, the per-cloud rules that Terraform validates, and the verification
steps for that cloud.

## Step 2: prerequisites

Check the shared tools and the per-cloud additions from the reference:

```bash
for t in terraform kubectl helm jq openssl curl base64 tinkey; do
  command -v "$t" >/dev/null 2>&1 && echo "ok  $t" || echo "MISSING $t"
done
```

`jq` is needed by `scripts/create-user.sh`; `openssl` hashes the organization
admin token during apply. Missing tools stop the run: point the user at the
install links in the README "Setup" section, or at the Dev Containers
configuration in this repo, which ships every tool preinstalled.

Ask whether the user has their GoodData.CN license key. If not, they get it from
their GoodData contact; nothing else in this skill works without it. Do not ask
them to paste it into the conversation.

## Step 3: scaffold settings.tfvars (gated)

`<env>/settings.tfvars` is gitignored and holds secrets, so it never appears in
git history. Creating it is the first change, so confirm before running:

```bash
cp <env>/settings.tfvars.example <env>/settings.tfvars
```

Then walk the required values in the example's order and ask for each one the
user has not given. Everywhere:

- `helm_gdcn_version`: keep the example's value unless the user names another.
- `gdcn_license_key`: the user pastes it into the file themselves. Tell them the
  line to edit and wait until they say it is done.
- `auth_hostname`: the Dex login hostname, separate from every organization
  hostname.
- `gdcn_orgs`: at least one organization with `id` (lowercase DNS label), `name`,
  `admin_user`, `admin_group`, and a `hostname` that is not `auth_hostname`.

Then the per-cloud required values from the reference. Leave every optional
block as the example ships it. Finish with `terraform fmt -check
<env>/settings.tfvars` (never `-diff`, which prints the file, secrets included)
and fix any formatting it reports.

## Step 4: authenticate

The reference names the login command; the user runs it. Verify with the
read-only identity call from the reference before spending time on a plan that
would fail on credentials.

## Step 5: init and plan checkpoint

```bash
cd <env>
terraform init
terraform plan -var-file=settings.tfvars -out=tfplan
```

Summarize the plan by resource type and count, and quote any validation error
verbatim: those messages name variables, never values, and they are the fastest
way to explain a rejected setting. Fix the tfvars value with the user, re-plan,
and only then move on. This is the first checkpoint: the user reads the summary
and confirms.

## Step 6: apply (gated)

Cloud environments apply once. Local applies twice, because the Kubernetes and
Helm providers cannot plan against a cluster that does not exist yet; the
reference has the exact two-phase sequence, and each phase is its own gate.

```bash
terraform apply tfplan && rm tfplan
```

Tell the user before starting: the gooddata-cn Helm release waits up to 3600
seconds for every pod and job, so a long apply is normal. Do not interrupt it
and do not run a second apply beside it. If the apply fails, run the
`troubleshoot-gdcn` skill through the Skill tool with the error text instead of
retrying blindly.

## Step 7: kubectl

```bash
../scripts/configure-kubectl.sh
kubectl get nodes
```

The script decides which cloud it is on from the current directory name, so it
must run from inside `aws/`, `azure/`, or `local/`.

## Step 8: verify the deployment

```bash
kubectl get pods -n gooddata-cn --field-selector=status.phase!=Running,status.phase!=Succeeded
kubectl get organization -n gooddata-cn
terraform output org_domains
```

The first command should print nothing once the rollout is complete; anything it
lists is still starting or failing. Every organization from `gdcn_orgs` must
appear in the second. Then run the "Verify" section of the cloud reference: it
covers DNS records, certificate state, and the HTTPS check for that cloud.

## Step 9: first user (gated)

Two paths, from the README:

- **External OIDC provider** (recommended beyond local testing): not managed by
  Terraform. Point the user at
  https://www.gooddata.com/docs/cloud-native/latest/manage-organization/set-up-authentication/
  and stop here.
- **Built-in Dex**: the user runs `../scripts/create-user.sh` from the
  environment directory. It prompts for the organization, email, name, and
  password, creates the user, and prints an API token. When Terraform created
  the organization, the script reads the admin credentials from the secret
  `gdcn-org-admin-<org_id>` on its own.

With `enable_observability = true`, `../scripts/create-grafana-user.sh` creates a
Grafana user the same way.

## Step 10: open the URL

`terraform output org_domains` lists the organization hostnames. Cloud
deployments open `https://<org_hostname>`. Local deployments open
`https://gooddata.localhost` and show a browser warning because the certificate
is self-signed.

## Step 11: report

Summarize for the user:

- Environment, `size_profile`, ingress and TLS choice, and the organizations
  created.
- DNS records they still have to create (from the reference's verify section),
  and the certificate state.
- What stays manual: external OIDC, Grafana users, extra organizations.
- How to tear down: the README "Tearing down" section, plus the per-cloud notes
  in the reference (on AWS, deletion protection must be switched off and
  applied before `terraform destroy` on prod profiles).

Quote variable names, never secret values.

## Derived from

- Repo: gooddata-cn-terraform, `README.md` Quickstart plus `variables.tf` and
  `settings.tfvars.example` under `aws/`, `azure/`, and `local/`. Re-verify
  against them after every pull.
- Chart: gooddata-cn 4.14.0 (the `helm_gdcn_version` in the example files when
  this skill was written).
- Docs: https://www.gooddata.com/docs/cloud-native/latest/manage-organization/set-up-authentication/
- Docs: https://www.gooddata.com/docs/cloud-native/latest/whats-new-cn/
- Last reviewed: 2026-09 by nortonsk.
