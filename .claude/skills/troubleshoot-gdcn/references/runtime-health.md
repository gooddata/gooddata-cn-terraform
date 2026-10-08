# Family E: slow or erroring product

Pods are Running but the product misbehaves: slow dashboards, API errors,
exports that fail or never finish, AI chat errors, stale data, or connection
errors in logs. The component names below come from the chart's workloads; the
"watch for" guidance is the same the shipped Grafana dashboard encodes.

| Symptom | Components to read | Metadata |
| --- | --- | --- |
| slow dashboards, query timeouts | `gooddata-cn-calcique`, `gooddata-cn-sql-executor`, `gooddata-cn-result-cache`, `gooddata-cn-afm-exec-api` | the customer's data warehouse does the heavy work |
| API 500 | `gooddata-cn-api-gateway`, then the upstream named in its log | |
| exports fail or hang | `gooddata-cn-export-controller`, `gooddata-cn-export-builder`, `gooddata-cn-tabular-exporter` | export-builder runs headless browsers |
| stale objects, delayed background jobs | Pulsar (`pulsar` namespace), `gooddata-cn-metadata-api` | |
| AI chat or semantic search errors | the gen-ai pods (`kubectl get pods -n gooddata-cn | grep -i -E 'gen-ai|genai|qdrant'`) | needs `enable_ai_features` and the AI entitlement |
| database errors | `gooddata-cn-metadata-api` first | RDS, Azure PostgreSQL, or CloudNativePG on local |

## Check these first

1. **Resource pressure and restarts.**
   ```bash
   kubectl top pods -n gooddata-cn --sort-by=memory | head -20
   kubectl get pods -n gooddata-cn | awk 'NR==1 || $4 > 0'
   ```
   A component at its memory limit or restarting is family B first.
2. **The component's log for the symptom.**
   ```bash
   kubectl logs -n gooddata-cn deploy/<component> --tail=300 | grep -i -E 'error|exception|timeout|refused'
   ```
   Read the first error, not the last; cascades start upstream.
3. **Dependencies.**
   ```bash
   kubectl get pods -n pulsar
   kubectl get pods -n gooddata-cn | grep -E 'redis|etcd'
   ```
   For the metadata database: AWS `aws rds describe-db-instances --profile
   <aws_profile_name> --query 'DBInstances[].[DBInstanceIdentifier,DBInstanceStatus]'`,
   Azure `az postgres flexible-server list -o table`, local
   `kubectl get clusters.postgresql.cnpg.io -n postgres` and `kubectl get pods -n postgres`.
4. **What changed.** A data refresh, a metric edit, a new workspace, a version
   bump, a change to the warehouse. Most "suddenly slow" reports follow one.

## Patterns

- **Slow with the API gateway healthy.** Time spent in `sql-executor` is time
  in the customer's warehouse. Slow warehouse queries are tuned there, not by
  scaling GoodData.CN. Calcique errors in the log usually mean an invalid
  metric or model definition in one workspace, which shows up as one broken
  dashboard rather than a slow platform.
- **5xx sustained on one upstream.** The named component is failing: OOM
  (family B), database connectivity (below), or a crash loop. Brief 5xx during
  a rollout is expected.
- **Exports.** Visual exports wait for a free headless browser in
  `export-builder`; long waits or failures mean the pool is saturated. More
  `export-builder` replicas, set through `gdcn_helm_extra_values` and a gated
  apply, is the supported change. Tabular export failures point back at the
  warehouse or Calcique.
- **Background jobs delayed, stale data after changes.** Pulsar consumers are
  behind or a message keeps failing. Pulsar pods not Running is family B;
  repeated exceptions in a consumer's log with healthy Pulsar is a ticket.
- **Database connection errors** (`Connection refused`, `password
  authentication failed`, `could not connect`, Hikari pool timeouts). Check the
  database status from step 3, then the network path: on AWS the RDS security
  group must admit the EKS nodes, on Azure the PostgreSQL firewall or private
  endpoint must admit the AKS subnet, on local the CloudNativePG pods must be
  Running with their Service endpoints populated
  (`kubectl get endpoints -A | grep -i postgres`). A pool that is full while the
  database is healthy means too many concurrent queries; that is a sizing
  question for a ticket, not a restart.
- **AI chat errors.** Confirm `enable_ai_features` is true, the gen-ai pods are
  Running, and the license includes the AI entitlement (family D, step 3). A
  provider or model that the deployment cannot reach shows up in the gen-ai
  pod log with the HTTP status from the provider.

## You can fix this yourself

Gated, one at a time:

- **Restart one component** that is Running but wedged (no restarts, no OOM,
  log stopped): `kubectl rollout restart deploy/<component> -n gooddata-cn`.
  Once. If the symptom returns, stop restarting and collect logs.
- **Scale a component** through `gdcn_helm_extra_values` (replica count or
  resources, in the shape of the size profile template), then plan and apply.
  Never `kubectl scale`; the next apply reverts it.
- **Open the network path** to the database in the cloud console (security
  group, firewall rule), a change the user makes, then re-check step 3.
- **Restart the local database pod** when it is Running but unresponsive:
  `kubectl delete pod <postgres pod> -n postgres`; CloudNativePG recreates it.

## Needs a GoodData support ticket

- Errors in a GoodData.CN component with healthy dependencies, no resource
  pressure, and no recent change.
- Sustained Pulsar consumer exceptions with Pulsar itself healthy.
- Slow queries where `sql-executor` shows fast warehouse responses.
- Connection pool exhaustion at default sizing under ordinary usage.

Do not restart the component again at this point.

## What to include

The log tails from step 2 with connection strings and tokens removed,
`kubectl top pods -n gooddata-cn`, the restart listing, the database status from
step 3, the `size_profile`, and a description of what the user was doing when
it started.

## Deeper investigation (observability on)

Open the `GoodData-CN / Overall Health` dashboard in Grafana, or query
Prometheus directly:

```bash
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

| Question | Panel or expression | Watch for |
| --- | --- | --- |
| Is the gateway returning errors | section 2, `http_server_request_duration_seconds_count{container="gateway-api-gw", http_response_status_code=~"5.."}` | sustained non-zero outside rollouts |
| Which upstream is failing | section 2, `forward_call_response_status_count_total{container="gateway-api-gw"}` | a drop for one upstream, or a 5xx surge on one |
| Where the latency is | section 4d, `calcique_get_sql_seconds_*` vs `sql_execute_seconds_*` | SQL executor dominating means the warehouse |
| Warehouse pool | section 4d, `sqlxhikaricp_connections_pending` | pending above zero |
| Cache effectiveness | section 4d, `result_cache_exec_registration_total{cacheHit="true"}` over total | sudden drops after refreshes, persistently low |
| Background jobs | section 4a, `pulsar_consumer_unacked_messages`, `pulsar_message_exception_total` | growing backlog, any exception rate |
| Exports | section 4e, `export_controller_browser_pool_acquire_seconds`, `export_duration_seconds_count{IS_SUCCESS="false"}` | waits above a second, failures by type |
| Errors in logs | section 5, Loki `{namespace="gooddata-cn"} |~ "(ERROR|WARN)"` | change relative to each service's baseline |

Loki is reachable the same way: `kubectl -n observability port-forward svc/loki 3100:3100`.

## See also

- Family B for pods under pressure, family D for license and login.
- `modules/k8s-common/dashboards/gooddata-cn-overall-health.md` for every
  panel's meaning.
