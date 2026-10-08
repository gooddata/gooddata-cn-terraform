# Family C: Terraform or Helm failed

An apply, plan, or destroy stopped with an error, or the gooddata-cn release is
not in the `deployed` state. Start from the exact error text; the patterns
below cover what the wording means and what to do.

## Check these first

1. **Plan again, read the first error.**
   ```bash
   terraform plan -var-file=settings.tfvars
   ```
   Validation errors name variables and are safe to quote. Provider or state
   errors are covered below.
2. **Release state.**
   ```bash
   helm list -A
   helm history gooddata-cn -n gooddata-cn
   helm status gooddata-cn -n gooddata-cn
   ```
   Healthy: the latest revision `deployed`. `failed` means the last upgrade
   errored; `pending-upgrade` or `pending-install` means an operation is still
   running or was interrupted.
3. **Credentials still valid.**
   ```bash
   aws sts get-caller-identity --profile <aws_profile_name>     # AWS
   az account show                                              # Azure
   kubectl config current-context; k3d cluster list             # local
   ```
4. **Is something else running.** A second `terraform` process, another
   terminal, or CI holding the state lock.

## Patterns and what they mean

- **`context deadline exceeded`, `timed out waiting for the condition`.** The
  gooddata-cn release waits up to 3600 seconds for every pod and job. Pods that
  never became Ready in that window are the cause: go to family B, fix, then
  re-apply (see below).
- **`another operation (install/upgrade/rollback) is in progress`.** A previous
  apply was interrupted and left the release `pending-upgrade`. Recovery is in
  the next section.
- **`ExpiredToken`, `failed to refresh cached credentials`, `The security token
  included in the request is invalid`.** The AWS SSO session expired, often
  during a long apply or destroy. The user runs
  `aws sso login --profile <aws_profile_name>` and re-runs the same command;
  Terraform resumes. Exporting keys into the environment does not help, because
  `aws/providers.tf` pins the named profile.
- **Azure `AADSTS` or `token expired`.** The user runs `az login` again.
- **`connection refused` or `no such host` from the Kubernetes or Helm
  provider, local only.** Either phase one of the local install never ran (the
  cluster does not exist), or `k3d_kubeapi_host` is wrong for this machine. Run
  `k3d cluster list`; if the cluster is missing, the `install-gdcn` skill's local
  reference has the two-phase sequence; if it exists, check
  `getent hosts host.docker.internal` and set `k3d_kubeapi_host = "127.0.0.1"` on
  a plain Linux host.
- **`Inconsistent dependency lock file`, `Required plugins are not installed`.**
  `.terraform.lock.hcl` is gitignored in this repo, so a fresh clone or a pull
  that changed provider versions needs `terraform init`. Plain `init` only
  writes the provider cache and lock file; `init -upgrade` changes pinned
  provider versions and is gated.
- **`Error acquiring the state lock`.** Confirm no other Terraform process is
  running (the lock info names the host and time). Only then
  `terraform force-unlock <id>`, gated.
- **`Unsupported argument`, `Missing required argument`, or a validation error
  about a variable the user never touched, right after a pull.** The example
  file gained or renamed variables. Run the `sync-settings-tfvars` skill through
  the Skill tool.
- **`Invalid helm_gdcn_version for selected features`.** `alb` needs chart
  3.51.0 or newer, `istio_gateway` 3.53.0 or newer. Raise the version or change
  the ingress choice.
- **Destroy hangs on an Organization or a namespace.** Family F.

## You can fix this yourself

Gated, one at a time:

- **Re-apply after fixing the cause.** This is the fix for a `failed` release
  and for most interrupted applies:
  `terraform plan -var-file=settings.tfvars -out=tfplan`, review,
  `terraform apply tfplan`, `rm tfplan`. Helm treats it as a new upgrade and
  completes what was left.
- **Clear a stuck `pending-upgrade`.** Only when `helm history` shows the
  newest revision pending and no apply is running:
  `helm rollback gooddata-cn <last deployed revision> -n gooddata-cn`. This
  makes the release state differ from Terraform's, so follow it immediately with
  the re-apply above; Terraform brings the release back to the intended
  version.
- **Fix a tfvars value** that a validation rejected, then plan and apply.
- **Re-run `terraform init`** after a pull or on a fresh clone.

Do not run `helm upgrade` by hand and do not delete the release. Both create
state Terraform will fight on the next apply.

## Needs a GoodData support ticket

- The apply fails inside the gooddata-cn chart with an error naming a GoodData
  component while every prerequisite pod (database reachable, Pulsar Running,
  Redis Running) is healthy.
- The same chart version applied cleanly before and fails now with no change in
  `settings.tfvars` or the repo.

Do not re-apply a third time at this point.

## What to include

The full Terraform error block (redact any connection string or token in it),
`helm history gooddata-cn -n gooddata-cn`, `helm status`, the chart version
(`helm_gdcn_version`), and the output of `git log -1 --oneline` for the repo
revision in use.

## Deeper investigation (observability on)

Not applicable; Terraform and Helm state are outside the metrics stack. Section
1's "Last Helm Deployment" panel confirms when the last successful rollout
happened, which helps date a regression.

## See also

- Family B for the pods that made the release time out.
- The `install-gdcn` skill's local reference for the two-phase apply.
