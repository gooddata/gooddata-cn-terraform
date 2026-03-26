# GoodData CN — Grafana Dashboards

Dashboard JSON files for monitoring GoodData CN deployments.

## gooddata-cn-overall-health.json

Single-pane-of-glass dashboard covering service readiness, API error rates,
query performance, exports, caching, and Pulsar messaging health.

**Requires:** Grafana 12.0+, Prometheus datasource, Loki datasource.

---

## Deployment options

### Option A — Automatic (gooddata-cn-terraform)

If you use **gooddata-cn-terraform**, the dashboard is provisioned automatically
via a Kubernetes ConfigMap after `terraform apply`. No manual steps needed.

### Option B — Grafana UI import

1. Open Grafana → **Dashboards → Import**
2. Upload `gooddata-cn-overall-health.json`
3. Before saving, replace the placeholder datasource UIDs:
   - `GDMIMIR` → your Prometheus datasource UID
   - `GDLOKI` → your Loki datasource UID
4. Click **Import**

### Option C — kubectl (any Kubernetes environment)

Substitute UIDs and create a ConfigMap that Grafana's sidecar picks up automatically:

```bash
sed -e 's/GDMIMIR/<your-prometheus-uid>/g' \
    -e 's/GDLOKI/<your-loki-uid>/g' \
    gooddata-cn-overall-health.json > /tmp/dashboard.json

kubectl create configmap grafana-dashboard-gooddata-cn \
  --from-file=gooddata-cn-overall-health.json=/tmp/dashboard.json \
  --namespace <grafana-namespace> \
  --dry-run=client -o yaml \
  | kubectl label --local -f - grafana_dashboard=1 -o yaml \
  | kubectl annotate --local -f - grafana_folder=GoodData-CN -o yaml \
  | kubectl apply -f -
```

> The ConfigMap requires the Grafana sidecar (`grafana-sc-dashboard`) to be
> enabled in your Grafana Helm release (`sidecar.dashboards.enabled: true`).

---

## Datasource UIDs

| Placeholder | Replace with |
|---|---|
| `GDMIMIR` | Your Prometheus datasource UID (gooddata-cn-terraform default: `prometheus`) |
| `GDLOKI` | Your Loki datasource UID (gooddata-cn-terraform default: `loki`) |

Find your UIDs in Grafana under **Connections → Data sources → (datasource) → Settings**.

---

## Updating the dashboard

After editing the dashboard in Grafana, export it via **Dashboard settings →
JSON model → Copy to clipboard**, replace UIDs back to placeholders, save the
JSON here, and commit.

Full documentation: [GoodData CN Observability Dashboards](https://gooddata.atlassian.net/wiki/spaces/INFRA/pages/3472883722)
