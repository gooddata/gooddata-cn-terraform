# Recovery: when the upgrade does not finish

Every action here changes the cluster or the release state. State the command,
explain the consequence, and wait for a yes before each one.

## Roll back to the previous version

The release belongs to Terraform, so a rollback is another upgrade in the other
direction. Change `helm_gdcn_version` back to the value from the step 1
snapshot, plan, review, apply. Helm records it as a new revision; that is
correct and expected. Data written by the newer version stays in place; the
release notes say whether a version's schema changes are reversible, so read
them before rolling back across a version that migrated data.

## The release is stuck in `pending-upgrade`

`helm history gooddata-cn -n gooddata-cn` shows the newest revision
`pending-upgrade` and Terraform reports "another operation is in progress".
This happens when the apply was interrupted (a closed terminal, an expired
cloud session, a killed process).

1. Wait first. If an apply might still be running somewhere, the release will
   settle on its own within the 3600 second timeout. Confirm nothing is running
   before touching the release.
2. Re-run the apply. Often Helm resumes and completes; this is the preferred
   path.
3. Only if the release stays pending, clear it by rolling Helm back to the last
   `deployed` revision:
   ```bash
   helm rollback gooddata-cn <last deployed revision> -n gooddata-cn
   ```
   This makes the release differ from what Terraform believes it applied. Follow
   it immediately with a plan and apply through the saved-plan flow, so
   Terraform brings the release to the intended version and the two agree
   again. Say this drift warning out loud before running the rollback.

## Pods do not become Ready after the upgrade

The Helm wait times out and the release lands in `failed`. The chart is
already at the new version; what failed is a pod. Run the `troubleshoot-gdcn`
skill through the Skill tool, family B, with the pod names. Once the cause is
fixed, re-run the apply; Helm completes the same upgrade. If the cause is the
new version itself, roll back as above and collect a support bundle before
reporting it.

## Never delete an Organization during a failed upgrade

Each Organization carries a finalizer that only the running organization
controller can clear. During a half-finished upgrade that controller may be the
pod that is not running, so a `kubectl delete organization` hangs and, worse,
recreating it later generates new admin bootstrap credentials. Leave the
Organizations alone; make the controller healthy and the rest follows.

## Custom resource definitions

- The Organization CRD and the Prometheus operator CRDs (ServiceMonitor,
  PodMonitor) must stay installed while releases reference them; removing them
  breaks the next `helm upgrade` of every release that uses them. On local the
  operator CRDs are pinned by `helm_prometheus_operator_crds_version`, which
  must match the `kube-prometheus-stack` version; on AWS and Azure they come
  with that chart.
- Never `kubectl delete crd` as a cleanup step.

## Changes that are not upgrades

- **`size_profile`.** Changing it after deployment is not a supported
  migration: volumes cannot shrink and growing them is a manual, storage-class
  dependent step. The supported route is a fresh deployment with the new
  profile and a data migration. Say so and stop.
- **Switching `ingress_controller` to or from `istio_gateway`.** Supported,
  but after the apply every workload needs a rollout restart so sidecars are
  added or removed: `kubectl -n <namespace> rollout restart deployment` and
  `statefulset` for `gooddata-cn`, `pulsar`, `observability` (and `seaweedfs`
  on local). Each restart is gated.
- **Other pins** (`helm_pulsar_version`, `helm_cert_manager_version`, the
  observability charts). They move through the same plan and apply flow, but
  read that chart's own release notes; this skill only knows the GoodData.CN
  gates.

## When none of this recovers the deployment

Run the `troubleshoot-gdcn` skill through the Skill tool, family C, with the
apply error, the `helm history` output, and the previous and target versions.
It ends in a support ticket with a bundle attached.
