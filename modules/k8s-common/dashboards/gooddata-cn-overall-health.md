# GoodData CN — Overall Health Dashboard

Single-pane-of-glass Grafana dashboard for monitoring a GoodData CN deployment.
Import `gooddata-cn-overall-health.json` into Grafana to use it.

**Data sources required:** Prometheus · Loki (optional — Loki panels are hidden if not connected)

## Importing into Grafana

1. In Grafana go to **Dashboards → Import** and upload this JSON file.
2. Map the data sources:
   - `${DS_PROMETHEUS}` → your Prometheus data source
   - `${DS_LOKI}` → your Loki data source (optional)
3. Click **Import**.

> If you use `gooddata-cn-terraform` with `enable_observability = true`, the dashboard is provisioned automatically under the **GoodData-CN** folder.

---

## Monitored Metrics Reference

### Section 1 — Cluster & Service Health

| Metric | Expression | Description |
|---|---|---|
| Nodes Ready | `kube_node_status_condition{condition="Ready"}` | K8s standard: ratio of nodes in Ready state. Anything below 100% means a node is unhealthy or being cycled. |
| Pods Ready | `kube_deployment_status_replicas_ready` / `kube_deployment_status_replicas` | K8s standard: ratio of pods passing readiness checks across deployments. |
| Service Readiness per Deployment | `kube_deployment_status_replicas_ready`, `kube_deployment_status_replicas`, `kube_pod_status_phase` | K8s standard: per-deployment ready vs desired, with stuck-pending detection. Pinpoints which specific GoodData CN component is unhealthy. |
| API 5xx Error Rate | `http_server_request_duration_seconds_count{container="gateway-api-gw", http_response_status_code=~"5xx"}` | Share of requests through the GoodData CN API gateway returning 5xx. **Watch for:** sustained non-zero values during normal operation — usually OOM kills, metadata DB connectivity issues, or upstream service crashes. Brief spikes during rolling deployments are expected. Cross-reference with OOM Kills and Pod Restart panels to localize the failing component. |
| OOM Kills | `kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}` | K8s standard: containers terminated by the OOMKiller. Any non-zero value warrants investigation — under-provisioned service or memory leak. |
| GoodData-CN Version | `kube_pod_container_info{container=~".*metadata-api.*"}` | Image tag of `metadata-api`, the canonical version marker for the deployment. Use to correlate performance changes or incidents with specific releases. |
| Last Helm Deployment | `kube_pod_start_time` (max) | K8s standard: timestamp of the most recent pod start, used as a proxy for the last `helm upgrade`. Helps determine if a recent deployment correlates with current symptoms. |

### Section 2 — API Traffic & Errors

| Metric | Expression | Description |
|---|---|---|
| API Request Rate by Upstream | `forward_call_response_status_count_total{container="gateway-api-gw"}` | Requests/s reaching each upstream service via the API gateway, by HTTP status class. **Watch for:** a sudden drop for one upstream — that service is down or unreachable; a surge in 4xx for one upstream typically means a client/auth problem; a 5xx surge isolates the failing component. The traffic distribution also reveals which subsystems are exercised by current user activity. |
| API Latency Distribution | `http_server_request_duration_seconds_bucket{container="gateway-api-gw"}` | Heatmap of request durations across all gateway traffic. **Watch for:** bands drifting upward over time (general degradation), and a heavy tail with a stable median (slow downstream — typically Calcique compute, SQL Executor, or a saturated connection pool). |
| Calcique Error Rate | `calcique_compute_errors_total` | Compute errors raised by **Calcique**, the GoodData CN analytics engine that translates AFM requests into SQL and orchestrates execution. **Watch for:** sudden increases — these manifest as broken dashboards for end users. Common causes: invalid LDM/metric definitions, datasource failures during compute, query timeouts, Calcique OOM. A small non-zero baseline is normal in multi-tenant environments (some workspaces always have malformed metrics). |
| Export Failure Rate | `export_duration_seconds_count{IS_SUCCESS="false"}` | Failed export jobs per second (PDF, XLSX, CSV, raw). **Watch for:** spikes — typically browser pool exhaustion for visual exports, datasource problems for tabular exports, or template rendering failures. Cross-reference with Browser Pool Pressure and Export Duration to localize. |
| Pulsar Exception Rate | `pulsar_message_exception_total` | Exceptions thrown by Pulsar consumers while processing background-job messages. **Watch for:** any sustained non-zero rate — a consumer is repeatedly failing on a message and the unacknowledged backlog will grow if unaddressed. Common causes: poison messages, downstream dependency outage, consumer bug. Often correlates with rising Unacknowledged Backlog. |
| Pod Restart Rate | `kube_pod_container_status_restarts_total` | K8s standard: container restart rate across services. Strong signal of OOM kills, liveness probe failures, or crash loops — cross-reference with OOM Kills. |

### Section 3 — Service Memory & CPU

| Metric | Expression | Description |
|---|---|---|
| Container Memory — Last / Avg / Max | `container_memory_working_set_bytes` (instant, avg_over_time, max_over_time) | K8s standard: working-set memory per container across the selected range. |
| Memory % of Requests | `container_memory_working_set_bytes` / `kube_pod_container_resource_requests{resource="memory"}` | K8s standard: memory usage relative to the configured request. Indicates whether the request is appropriately sized. |
| Memory % of Limits | `container_memory_working_set_bytes` / `kube_pod_container_resource_limits{resource="memory"}` | K8s standard: memory usage relative to the configured limit. Proximity to 100% is a precursor to OOM kills. |
| CPU Usage % of Requests | `container_cpu_usage_seconds_total` / `kube_pod_container_resource_requests{resource="cpu"}` | K8s standard: CPU usage versus configured request. Sustained >100% means the request is under-sized for actual load. |
| CPU Throttling | `container_cpu_cfs_throttled_periods_total` / `container_cpu_cfs_periods_total` | K8s standard: share of scheduling periods where the container was throttled. Non-zero values mean the container is being slowed by the kernel scheduler even if raw CPU usage looks healthy. |
| OOM Kills & Restarts by Service | `kube_pod_container_status_restarts_total`, `kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}` | K8s standard: per-service restart and OOM history. |

### Section 4a — Background Jobs (Pulsar)

| Metric | Expression | Description |
|---|---|---|
| Message Rates | `pulsar_message_send_total`, `pulsar_message_ack_total` | Pulsar message production (`send`) and acknowledgement (`ack`) rates per consumer. Pulsar is the message bus driving GoodData CN's asynchronous work — workspace sync, organization changes, cache invalidations, object lifecycle events. **Watch for:** in a healthy system `ack ≈ send`. If `send >> ack`, consumers are falling behind and a backlog will form. Sustained imbalance is a serious issue. |
| Unacknowledged Backlog | `pulsar_consumer_unacked_messages` | Outstanding unprocessed messages per topic. **This is the single most actionable Pulsar metric.** **Watch for:** sustained non-zero backlog — background jobs are queuing faster than consumers can drain them, producing user-visible symptoms like delayed object visibility, stale caches, and slow workspace operations. A growing backlog together with a non-zero Pulsar Exception Rate signals a poison message blocking the consumer; otherwise the consumer is typically under-scaled. |

### Section 4b — Redis

| Metric | Expression | Description |
|---|---|---|
| Replica Role Status | `redis_instance_info{role="slave\|master"}` | Role (master/replica) of each Redis pod over time. GoodData CN uses Redis for shared state including session data and rate-limiting counters. **Watch for:** at least one master must always be present — if all pods show as replicas, writes will fail. Frequent role flapping signals Redis Sentinel/cluster instability, usually from network issues or aggressive eviction. |

### Section 4c — PostgreSQL & Hikari

GoodData CN's metadata database holds canonical state — workspaces, users, LDMs, metric definitions, ACLs, dashboard layouts. Java services access it via per-service Hikari connection pools. This section visualizes active PostgreSQL connections per database and Hikari pool utilization per application. **Watch for:** Hikari `active` approaching `max` means the pool is saturated and requests will queue waiting for a free connection, inflating API latency invisibly. Sustained saturation needs either a pool sizing increase or query-side optimization upstream.

### Section 4d — Analytics Engine (Calcique / SQL Executor / Result Cache)

| Metric | Expression | Description |
|---|---|---|
| Calcique Latency (avg & peak) | `calcique_get_sql_seconds_sum/count`, `calcique_get_sql_seconds_max` | Time Calcique spends planning and orchestrating a single analytics request — AFM-to-SQL translation, dispatch to SQL Executor, result assembly. **Watch for:** avg latency reflects typical dashboard widget load — values above a few seconds feel sluggish to end users; peak reveals worst-case widgets (complex metrics, large workspaces). Sustained increases usually indicate cache misses, datasource slowness, or insufficient Calcique replicas. |
| Calcique Error Rate | `calcique_get_sql_errors_total` | Calcique API errors per minute, distinct from the compute errors in Section 2. **Watch for:** these are API-surface failures — malformed AFM requests, auth failures, Calcique-internal errors — and tell you whether the problem is at the API layer or during execution. |
| SQL Executor Duration | `sql_execute_seconds_sum/count`, `sql_execute_seconds_max` | Time spent executing SQL against the customer's external datasource (DWH). **Watch for:** in most deployments this is the **dominant** component of analytics latency. Slow durations point to a slow DWH or inefficient queries, not GoodData CN. Peak values approaching the configured query timeout mean queries are about to fail. Resolution is usually DWH tuning or metric rewrites — not scaling GoodData CN. |
| External DS Pool Pending | `sqlxhikaricp_connections_pending` | Requests waiting for an available connection to the customer's external datasource (sqlx Hikari pool). **Watch for:** sustained `pending > 0` — the pool is exhausted, so queries are queued instead of running, adding latency invisible in SQL Executor Duration alone. Resolution: increase the pool's `maxPoolSize`, or scale the customer's DWH if it can't accept more concurrent connections. |
| Result Cache Hit Ratio | `result_cache_exec_registration_total{cacheHit="true"}` / total | Fraction of analytics requests served from cache instead of recomputed. The result cache shields both Calcique and the customer's DWH from load. **Watch for:** stable systems with frequent dashboard reuse typically see 70–90%; sudden drops usually mean cache invalidations (data refreshes, metric edits) or a flood of new/uncached requests. Persistently low (<30%) suggests an undersized cache or highly varied workload. |

### Section 4e — Exports

| Metric | Expression | Description |
|---|---|---|
| Export Duration (avg & peak) | `export_duration_seconds_sum/count`, `export_duration_seconds_max` | Time to render a single export, by type. Visual exports (dashboard PDFs/PNGs via headless browsers) are inherently slower than tabular (CSV/XLSX). **Watch for:** trends over time more than absolute values — a doubling of avg duration without traffic change signals a regression. Peak durations near the export timeout will surface as failures. |
| Export Failure Rate | `export_duration_seconds_count{IS_SUCCESS="false"}` | Failed exports/s by type and format. **Watch for:** visual export failures most often trace to browser pool exhaustion or browser crashes; tabular failures usually mean datasource or Calcique problems during data fetch. |
| Browser Pool Pressure | `export_builder_browser_pool_acquire_seconds` | Average time a visual export waits to acquire a headless browser from the export-builder pool. **Watch for:** sub-second is healthy. Seconds-long acquire times mean incoming visual exports are blocked behind in-flight ones — scale out export-builder replicas or increase the per-pod pool size. Persistent pressure during peak hours warrants a capacity review. |

### Section 5 — Error Logs (Loki, optional)

| Metric | Query | Description |
|---|---|---|
| ERROR/WARN Log Rate by Service | `{namespace=~"$ns"} \|~ "(ERROR\|WARN)"` | Rate of ERROR/WARN log lines per service. **Watch for:** baseline rates differ widely between services — some are inherently chatty. What matters is sudden change relative to each service's normal baseline, not absolute rates across services. |
| Component Error Log Streams | LogQL per container group | Filtered streams for the API gateway, analytics engine (Calcique + SQL Executor), and export pipeline. Use these for drill-down once a numeric panel has flagged an anomaly. |
