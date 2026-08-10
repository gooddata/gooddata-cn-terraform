# Changelog

Notable changes to this deployment project. This repo is not versioned; entries are dated.

## 2026-08 — Horizontal autoscaling

GoodData.CN services now scale horizontally on CPU utilization, **enabled by default**.
Requires `helm_gdcn_version >= 4.12.0`, the release that introduced autoscaling support in the
gooddata-cn Helm chart.

- Deploys [KEDA](https://keda.sh/), plus the Kubernetes Metrics Server on AWS (EKS does not ship it).
- Nine components scale independently: `metadata-api`, `api-gw`, `auth-service`, `afm-exec-api`,
  `calcique`, `result-cache`, and the three UI services (`analytical-designer`, `dashboards`,
  `home-ui`).
- Replica bounds follow the size profile: 1–3 for `dev`, 2–5 for production profiles. On AWS,
  Karpenter provisions nodes as pods scale out.
- Stateful and quorum-based components (PostgreSQL, Redis, etcd, Pulsar, Qdrant) are not autoscaled.
- Set `enable_gdcn_autoscaling = false` to disable — required if you pin a chart older than 4.12.0.
- Per-component settings can be overridden via `gdcn_helm_extra_values`.

See [Autoscaling](README.md#autoscaling) for the component table, tuning and rollback.
