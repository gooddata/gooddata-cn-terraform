---
name: upgrade-gdcn
description: Walk through upgrading a GoodData.CN deployment managed by this repo - pull repo updates, sync settings.tfvars through the sync-settings-tfvars skill, choose and validate the target helm_gdcn_version against the ingress version gates, run plan with a review checkpoint, apply only after explicit confirmation, verify the rollout, and recover if it fails. Use whenever the user wants to upgrade, update, bump, or move to a newer GoodData.CN or Helm chart version, asks whether a version works with alb or istio_gateway, asks what changed after a git pull, wants to change any chart or module version pin, or needs to roll back or recover a failed or stuck upgrade. Not for changing size_profile, which is not a supported migration, and not for first installs (install-gdcn) or for a deployment that is already broken before the upgrade (troubleshoot-gdcn).
---

# Upgrade GoodData.CN with this repo

The README's upgrade procedure is three steps: pull the repo, change
`helm_gdcn_version` in `settings.tfvars`, apply. This skill is those three steps
plus the checks around them: a snapshot before, a settings sync and a version
validation in the middle, a verification after, and a recovery path when the
apply does not finish. The user confirms every change.

## Rules

- **Read freely, change only with a yes.** `terraform plan`, `terraform output`,
  `kubectl get`, `kubectl describe`, `kubectl logs`, `helm list`, `helm history`,
  `helm status`, `helm get metadata`, `helm search repo`, `git fetch`, and
  `git diff` run without asking. Anything that changes files, Terraform state,
  or the cluster is listed first, with the exact command, and runs only after
  the user answers yes: `git pull`, every edit to `settings.tfvars`, every
  `terraform apply`, every `helm rollback`.
- **Applies use a saved plan.** `terraform plan -var-file=settings.tfvars
  -out=tfplan`, summarize, wait for a yes, `terraform apply tfplan`, then
  `rm tfplan`. The plan file embeds variable values, including the license
  key. Never `-auto-approve`, and never answer Terraform's own prompt on the
  user's behalf.
- **Secrets stay out of the conversation.** Read single non-secret values from
  `settings.tfvars` with `grep`, never `cat` the file. Refer to the license and
  every token by variable or secret name only.
- **The target version is never guessed.** It comes from the user or from the
  What's New page linked below. The current version and the target are the two
  values this skill changes; nothing else in `settings.tfvars` moves unless the
  sync step adds a new variable.
- **`helm rollback` is not the recovery path.** The release is owned by
  Terraform; recovery is another gated `terraform apply` with the previous
  version. The one exception, a release stuck in `pending-upgrade`, is in
  `references/recovery.md` with its drift warning.
- **Do not upgrade a broken deployment.** If the snapshot in step 1 shows pods
  that are not Ready or a release that is not `deployed`, run the
  `troubleshoot-gdcn` skill through the Skill tool first.
- **Other skills are called by name** through the Skill tool
  (`sync-settings-tfvars`, `troubleshoot-gdcn`). Never restate their
  procedures.

## Step 1: snapshot the deployment

From the environment directory (`aws/`, `azure/`, or `local/`):

```bash
helm history gooddata-cn -n gooddata-cn
kubectl get pods -n gooddata-cn --field-selector=status.phase!=Running,status.phase!=Succeeded
kubectl get organization -n gooddata-cn
grep -E '^helm_gdcn_version' settings.tfvars
terraform plan -var-file=settings.tfvars
```

Healthy: the latest revision `deployed`, an empty pod list, every organization
present, and a plan with no changes. A plan that already wants to change
something means drift or an unfinished earlier apply; settle that first,
otherwise the upgrade gets blamed for it. Keep the organization list and the
current version for the comparison in step 6.

## Step 2: pull the repo (gated)

```bash
git fetch origin
git log --oneline HEAD..origin/master
git diff HEAD..origin/master --stat
git diff HEAD..origin/master -- settings.tfvars.example
```

Summarize what moved: module changes, other `helm_*_version` pins (the repo
keeps about fifteen, and automated updates bump them regularly), and the
example file. Then, after confirmation, `git pull --ff-only`. A pull that is
not a fast-forward means local commits exist; stop and ask how the user wants
to handle them.

Then run the `sync-settings-tfvars` skill through the Skill tool. It merges new
variables and refreshed comments from the example into the user's
`settings.tfvars` without touching values they set, and reports any default
that flipped. Do not restate or shortcut its procedure here.

## Step 3: choose and validate the target version

Available versions, newest first, and what changed in them:

```bash
helm repo add gooddata https://charts.gooddata.com >/dev/null 2>&1; helm repo update gooddata >/dev/null
helm search repo gooddata/gooddata-cn --versions | head -15
```

Release notes: https://www.gooddata.com/docs/cloud-native/latest/whats-new-cn/

Before editing, check the target against the gates Terraform enforces at plan
time:

| Setting in `settings.tfvars` | Minimum `helm_gdcn_version` |
| --- | --- |
| `ingress_controller = "alb"` (AWS) | 3.51.0 |
| `ingress_controller = "istio_gateway"` | 3.53.0 |

A version carrying build metadata (`1.2.3+abc`) skips these checks. A target
below a floor is rejected by `terraform plan` with a message that names the
setting, so the outcome is the same either way; checking first saves a plan.

Jumping several minor versions in one step is supported by the chart, but the
release notes may list migration steps between them; read the notes for every
version being skipped. Downgrades are not part of this skill: point at the
release notes and stop.

Then, after confirmation, change the one line:

```bash
sed -i 's/^helm_gdcn_version = ".*"/helm_gdcn_version = "<target>"/' settings.tfvars
grep -E '^helm_gdcn_version' settings.tfvars
```

## Step 4: init and plan checkpoint

```bash
terraform init
terraform plan -var-file=settings.tfvars -out=tfplan
```

`terraform init` is expected after a pull: `.terraform.lock.hcl` is gitignored
in this repo, so provider changes need it. Read the plan and check three
things before asking for confirmation:

- The `gooddata-cn` Helm release changes its chart version and nothing else
  unexpected. Other Helm releases may change too when the pull bumped their
  pins; list them so the user knows the apply is wider than one chart.
- No resource is planned for `replace` or `destroy` that holds data: a
  StatefulSet, a PersistentVolumeClaim, the database, an object storage bucket.
  Any of those is a stop condition; report it and do not apply until the user
  understands why it is there.
- No Organization is planned for recreation. Recreating one loses its admin
  bootstrap credentials.

Summarize by resource type and quote any validation error verbatim.

## Step 5: apply (gated)

```bash
terraform apply tfplan && rm tfplan
```

Say beforehand that the gooddata-cn release waits up to 3600 seconds for every
pod and job, so a long apply is normal, and that the session must stay open.
A killed session leaves the release in `pending-upgrade`; the recovery
reference covers that. If the apply fails, do not retry immediately: read the
error, then follow `references/recovery.md`.

## Step 6: verify

```bash
helm history gooddata-cn -n gooddata-cn
helm get metadata gooddata-cn -n gooddata-cn
kubectl get pods -n gooddata-cn --field-selector=status.phase!=Running,status.phase!=Succeeded
kubectl get pods -n gooddata-cn | awk 'NR==1 || $4 > 0'
kubectl get organization -n gooddata-cn
terraform output org_domains
```

Pass criteria: the newest revision `deployed`; the chart version in
`helm get metadata` equals the target; the not-Running list empty; no restart
counts that rose since the snapshot; the organization list unchanged; and
`curl -kIs https://<org_hostname>` returning 200 or a redirect to the auth
hostname. Ask the user to log in once and open a dashboard; that is the check
no command replaces.

With `enable_observability = true`, the API 5xx panel in the
`GoodData-CN / Overall Health` dashboard (section 1) should return to its
pre-upgrade level within a few minutes of the rollout.

## Step 7: report

- Previous and new `helm_gdcn_version`.
- Every other pin the pull moved and the apply changed.
- Variables the sync added to `settings.tfvars`, and any default that flipped.
- Anything the plan showed that was not applied, and why.

Quote variable names, never secret values.

## Derived from

- Repo: gooddata-cn-terraform, `README.md` "Upgrading GoodData.CN", the
  `helm_gdcn_version` validation blocks in `aws/variables.tf`,
  `azure/variables.tf`, and `local/variables.tf`,
  `modules/k8s-common/gooddata-cn.tf` (release timeout) and
  `modules/k8s-common/gooddata-orgs.tf` (Organization finalizer). Re-verify
  against them after every pull.
- Chart: gooddata-cn 4.14.0 (the `helm_gdcn_version` in the example files when
  this skill was written).
- Docs: https://www.gooddata.com/docs/cloud-native/latest/whats-new-cn/
- Last reviewed: 2026-09 by nortonsk.
