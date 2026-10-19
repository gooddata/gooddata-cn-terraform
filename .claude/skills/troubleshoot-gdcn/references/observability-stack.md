# Family G: the observability stack itself

Grafana is unreachable, dashboards are missing, Loki shows nothing, or
Prometheus runs out of disk. Only relevant when `enable_observability = true`.
The stack lives in the `observability` namespace: kube-prometheus-stack
(Prometheus, kube-state-metrics, node-exporter), Loki in single-binary mode,
Promtail, Tempo, and Grafana. There is no alerting component in it.

## Check these first

1. **Is it enabled and where.**
   ```bash
   terraform output enable_observability
   terraform output observability_hostname
   kubectl get pods -n observability
   ```
   Every pod Running; Promtail is a DaemonSet with one pod per node.
2. **Grafana reachable.** Same DNS and TLS rules as family A, for
   `observability_hostname`. `curl -kIs https://<observability_hostname>` should
   return 200 or a redirect to the login page.
3. **Dashboards present.**
   ```bash
   kubectl get configmap -n observability -l grafana_dashboard=1
   ```
   Expected: the two GoodData-CN dashboards plus six Kubernetes dashboards.
   The Kubernetes ones are downloaded from GitHub during `terraform apply`; a
   cluster without egress to `raw.githubusercontent.com` at apply time ends up
   without them.
4. **Logs arriving.**
   ```bash
   kubectl get daemonset -n observability
   kubectl logs -n observability daemonset/promtail --tail=50
   kubectl logs -n observability -l app.kubernetes.io/name=loki --tail=50
   ```
5. **Disk.**
   ```bash
   kubectl get pvc -n observability
   kubectl -n observability exec prometheus-kube-prometheus-stack-prometheus-0 -- df -h /prometheus
   ```

## You can fix this yourself

Gated where they change anything:

- **Grafana not reachable.** Family A for the observability hostname; the
  ingress and certificate are created the same way as the organization's.
- **Missing Kubernetes dashboards.** Restore egress to GitHub for the apply,
  then re-run `terraform apply` through the saved-plan flow; the download
  happens again. The GoodData-CN dashboards come from ConfigMaps in the repo and
  never depend on egress.
- **Loki empty.** Promtail pods missing on some nodes (taints or resources,
  family B), or the retention window (`loki_retention_period`, default 168h,
  must be a multiple of 24h) already expired the range being queried. Widen the
  Grafana time range first.
- **Prometheus disk full.** The volume never shrinks. Lower
  `prometheus_retention_period` in `settings.tfvars` and apply; Prometheus
  drops old blocks within a couple of hours. Growing the volume is a
  storage-class dependent, manual step outside this skill.
- **Grafana admin password unknown.** `scripts/create-grafana-user.sh` reads it
  from the `grafana` secret in the `observability` namespace and creates a new
  user; the user runs it from the environment directory. Never print the
  secret.

## Needs a GoodData support ticket

The observability stack is upstream software configured by this repo. Open an
issue on the repo rather than a product ticket when a default in
`modules/k8s-common/observability.tf` is wrong for a supported profile. Product
tickets apply only when GoodData.CN components stop exposing metrics that the
dashboard expects.

## What to include

`kubectl get pods -n observability`, the Promtail and Loki log tails, the
ConfigMap listing, and the retention values in use.

## Deeper investigation (observability on)

This family diagnoses the stack itself, so the kubectl checks are the deeper
layer. Once Prometheus answers,
`kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090`
and `up` in the query box lists every scrape target and its state.

## See also

- Family A for the hostname, family B for the stack's pods.
- The README "Observability" section for dashboard import into another Grafana.
