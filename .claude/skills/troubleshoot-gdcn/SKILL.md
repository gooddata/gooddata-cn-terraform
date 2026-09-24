---
name: troubleshoot-gdcn
description: Diagnose a GoodData.CN deployment created by this repo by routing the user's symptom to the right checks - cannot open the UI or login page, DNS, certificate, or ingress errors, pods Pending, CrashLoopBackOff, OOMKilled, ImagePullBackOff, or ContainerCreating, terraform apply or helm timeouts, "connection refused" from the Kubernetes provider, expired cloud credentials, organization or Dex login failures, an invalid or expired license, slow dashboards, API 5xx, exports failing, terraform destroy hanging or namespaces stuck Terminating, and a Grafana or Loki stack that shows nothing. Works with kubectl alone and adds Prometheus and Loki queries only when enable_observability is on. Use whenever the user says something is broken, not working, stuck, failing, timing out, unreachable, or asks what to send to GoodData support. Reads and plans freely; changes nothing without explicit confirmation. Not for first installs (install-gdcn) or version bumps (upgrade-gdcn).
---

# Troubleshoot a GoodData.CN deployment

This skill takes a symptom, runs the read-only checks that eliminate the most
likely causes first, proposes fixes the user can apply themselves, and, when the
problem survives that, produces a support ticket with everything GoodData needs
attached. It works with `kubectl` and `terraform` alone; the observability
stack, when enabled, adds a deeper layer but is never required.

## Rules

- **Read freely, change only with a yes.** `terraform plan`, `terraform output`,
  `kubectl get`, `kubectl describe`, `kubectl logs`, `kubectl top`, `helm list`,
  `helm history`, `helm status`, `dig`, `curl`, and cloud CLI `describe`, `show`,
  and `list` calls run without asking. Anything that changes files, Terraform
  state, or the cluster is listed first, with the exact command, and runs only
  after the user answers yes. That includes `kubectl delete`, `kubectl patch`,
  `kubectl scale`, `kubectl rollout`, every `terraform apply` or `destroy`, and
  every script under `scripts/` that talks to a cloud API.
- **Applies use a saved plan.** Edit the tfvars value, run
  `terraform plan -var-file=settings.tfvars -out=tfplan`, summarize, wait for a
  yes, run `terraform apply tfplan`, then `rm tfplan`. Never `-auto-approve`.
- **Secrets stay out of the conversation.** Check that a secret exists with
  `kubectl get secret <name> -n gooddata-cn`, never with `-o yaml`. Never `cat` a
  tfvars file and never run `terraform output -json` without an output name.
  Quote log lines only after removing tokens, passwords, and connection strings.
- **Precheck first.** Run the four checks in the next section before following
  any family, and ask what changed recently: a pull, an apply, a version bump,
  a change made in the cloud console, or nothing at all.
- **Prefer a self-fix.** Every reference has a "You can fix this yourself"
  section; exhaust it before the ticket step.
- **No loop-backs.** When the user says a step did not help, that step and its
  variants are closed. Move to the next check, the next family, or the ticket.
  Never suggest the same fix again with different wording.
- **Degrade gracefully.** When `enable_observability` is false or the
  `observability` namespace has no pods, skip every block marked "observability
  on". The kubectl path in each reference is complete on its own.
- **Name the ingress path.** Read the value first (`terraform output
  ingress_controller` on AWS; the tfvars value elsewhere) and apply only the
  checks for that path: `alb` (AWS default), `ingress-nginx` (Azure and local
  default), or `istio_gateway`.
- **This stack has no alerting component.** Do not ask the user about firing
  alerts or tell them to check any.
- **Terraform owns the cluster objects.** A change made with `kubectl edit`,
  `kubectl scale`, or `helm upgrade` by hand is undone by the next apply. Fixes
  that must last go through `settings.tfvars`.
- **Other skills are called by name** through the Skill tool
  (`sync-settings-tfvars`, `install-gdcn`). Never read their files by path.

## Prechecks

Run all four from the environment directory (`aws/`, `azure/`, or `local/`) and
report the results before anything else:

```bash
kubectl get nodes
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
helm list -A
terraform output org_domains; terraform output auth_hostname
```

Healthy: every node Ready, the pod list empty, every release `deployed`, the
hostnames the user expects. Anything else already points at a family below.
Then ask what changed recently.

## Routing table

Match the user's words against the second column, read that reference in full,
and start with its "Check these first" section. When several families match,
follow the precedence in the next section.

| Family | The user says | Reference |
| --- | --- | --- |
| A | site does not load, login page never appears, NXDOMAIN, name not resolving, certificate invalid or pending, NET::ERR_CERT, 502, 503, 504 from the load balancer, ALB unhealthy, redirect loop to auth host | `references/reach-ui.md` |
| B | Pending, 0/3 nodes are available, Insufficient cpu or memory, CrashLoopBackOff, OOMKilled, ImagePullBackOff, ContainerCreating forever, pod restarts, disk pressure | `references/pods-and-capacity.md` |
| C | terraform apply failed or timed out, context deadline exceeded, helm release failed or pending-upgrade, another operation in progress, connection refused from the Kubernetes provider, ExpiredToken, SSO session expired, state lock, Inconsistent dependency lock file, unsupported argument after a pull | `references/terraform-and-helm.md` |
| D | invalid credentials, cannot log in, login loop, organization not found, create-user.sh fails, organization stuck, Dex error, license invalid or expired, admin token rejected | `references/auth-and-orgs.md` |
| E | dashboards slow, API 500, query timeout, exports never finish or fail, AI chat errors, stale data, background jobs delayed, database connection errors in logs | `references/runtime-health.md` |
| F | terraform destroy hangs or fails, namespace stuck Terminating, load balancer or volumes left behind, DeletionProtection, nodes will not drain, subnet has dependencies | `references/teardown.md` |
| G | Grafana 404 or unreachable, dashboards missing, Loki shows nothing, no data in panels, Prometheus disk full | `references/observability-stack.md` |

Every reference uses the same six headings: Check these first, You can fix this
yourself, Needs a GoodData support ticket, What to include, Deeper investigation
(observability on), See also.

## Precedence when families overlap

F, then C, then B, then A, then D, then E, then G. An unfinished destroy
explains everything; an apply that never completed explains unhealthy pods;
unhealthy pods explain every symptom downstream of them. Diagnose the upstream
family first and only continue when it comes back clean.

## The ticket step

When a reference lands in "Needs a GoodData support ticket", or the user has
tried every self-fix, open `references/support-ticket.md`. It produces a support
bundle from `scripts/support-bundle.yaml`, fills the ticket template from the
checks already run, and says where to send it. Do not skip the bundle: it is the
difference between a one-message ticket and a week of back and forth.

## Derived from

- Repo: gooddata-cn-terraform, `README.md`, `scripts/*.sh`, `modules/k8s-common`
  (`gooddata-cn.tf`, `gooddata-orgs.tf`, `observability.tf`), and
  `modules/k8s-common/dashboards/gooddata-cn-overall-health.md`. Re-verify
  workload names and outputs against them after every pull.
- Chart: gooddata-cn 4.14.0 (workload names taken from its rendered manifests).
- Docs: https://www.gooddata.com/docs/cloud-native/latest/manage-organization/set-up-authentication/
- Docs: https://troubleshoot.sh/docs/
- Last reviewed: 2026-09 by nortonsk.
