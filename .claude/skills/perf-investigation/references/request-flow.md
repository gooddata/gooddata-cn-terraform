# GoodData.CN request flow (for perf investigation)

The dependency map you need for step 3 (map the request path) and for telling a
**cause** apart from a **victim**. Annotated with what tends to gate each hop, so
you know where to look once a trace points you at a service. This map only names
the *plausible* downstream; trace decomposition (step 4) is what proves where
the time actually went.

Contents: Entry and routing · AFM execution (the critical path) · Export flow ·
Verifying the map against the live system.

## Entry and routing

```
Client (HTTPS) → Ingress (TLS, LB) → api-gw (gateway) → backend service
```

`api-gw` authenticates, resolves the organization, applies rate limits, and
**forwards** each request to a backend over an HTTP client. That forward path
holds a connection for the *entire* downstream execution, so under load the
gateway's forward connection pool is a common, non-obvious throughput ceiling —
api-gw itself can sit near-idle while requests queue waiting for a forward slot.

Routing (URL pattern → backend), from the gateway's application config:

| Path pattern | Backend |
|---|---|
| `/api/v*/actions/workspaces/*/execution/*`, `/ai/*`, `/ailake/*` | afm-exec-api |
| `/api/v*/auth/*`, `/login*`, `/oauth2/*`, `/logout`, `/api/v*/profile` | auth-service |
| `/api/v*/actions/workspaces/*/automations/*`, `/actions/notificationChannels/*` | automation |
| `/api/v*/actions/dataSources/*/scan*`, `/test` | scan-model |
| `/api/v*/actions/workspaces/*/export/(tabular\|visual\|raw\|slides\|image)*` | export-controller |
| `/api/v*/actions/collectCacheUsage`, `/actions/fileStorage/*` | result-cache |
| `/api/v*/entities/*`, `/api/v*/layout/*`, `/api/v*/actions/*` (catch-all) | metadata-api |
| `/analyze/*`, `/dashboards/*`, `/modeler/*`, `/*` (UI static assets) | api-gateway |

So: a slow `/execution/...` is afm-exec-api's chain; a slow `/profile` or
`/login` is auth-service (which itself calls metadata-api); a slow `/entities`
or `/layout` is metadata-api directly. Knowing this stops you investigating the
wrong backend for a given slow URL.

## AFM execution — the critical path

This is the workflow behind dashboard/report loads and the one most worth
understanding. GoodData generates SQL; the customer's own data source executes
it.

```
POST .../execution/afm/execute
  └─ afm-exec-api            parse AFM, resolve MAQL, orchestrate
       ├─(gRPC) metadata-api    LDM, data-source config, permissions   [sync]
       ├─(gRPC) calcique        MAQL → SQL (Calcite)                    [sync]
       └─(gRPC) result-cache    register execution, check cache         [sync]
            │
            ▼  CACHE MISS only:
            result-cache ──(Pulsar: sql.select)──▶ sql-executor          [async]
                 sql-executor: JDBC to customer data source, then
                   stores raw result into quiver (Arrow Flight DoPut)
                 sql-executor ──(Pulsar: execution.finish)──▶ result-cache [async]
            result-cache ──(Pulsar: result.xtab)──▶ quiver dataframe      [async]
                 quiver: cross-tabulate / pivot / sort / paginate (polars)
  → afm-exec-api returns a resultId

GET .../execution/afm/execute/result/{resultId}
  └─ served from quiver (Arrow Flight DoGet), paginated                  [sync]
```

Reading this for diagnosis:

- **Cache hit vs. miss is the biggest latency fork.** A hit skips the entire
  Pulsar/sql-executor/cross-tab path and just serves the stored result flight.
  If "slow" correlates with misses, the question becomes *why so many misses*
  (working set vs. cache capacity, eviction churn, cache-key volatility), which
  can be a far bigger lever than tuning any single service.
- **`sql.select` backlog** building = the cache-miss SQL path can't keep up.
  But check *why*: sql-executor may be idle and blocked on its **downstream**
  (the Arrow Flight DoPut into quiver, or the customer data source itself) —
  classic victim-not-cause. Compare sql-executor CPU and its fetch-vs-exec time.
- **`result.xtab` backlog / cross-tab latency** = the dataframe/cross-tab stage.
  The compute is usually tiny; if tasks sit a long time, they're queued or
  blocked on reading their input flight from the cache tier (again, follow the
  trace before blaming the cross-tab service).
- **Result fetch (`/result/{id}`)** is a synchronous read from the cache tier.
  If *that* is slow while the cache node has spare CPU, suspect a per-node
  coordination/consistency gate or a hot shard rather than throughput.
- **metadata-api and calcique are on the synchronous front of every execute**,
  so if they're slow (e.g., a connection-pool or DB ceiling on metadata-api),
  *every* report pays it — a uniform per-request tax across many endpoints is a
  tell for this rather than for the per-report compute path.

## Export flow (lower-frequency, but heavy)

```
POST .../export/(tabular|visual|raw|slides)
  └─ export-controller   (lifecycle/state in Redis)
       └─(Pulsar: export-*-scheduled.request)──▶
            tabular-exporter (CSV/XLSX)                    OR
            export-builder (PDF/PPTX/PNG via headless Chromium)
  → stored in object storage
```

Exports are async and resource-heavy (headless browser for visual/PDF). They
rarely cause interactive-load slowness, but they can compete for cluster CPU and
memory during a window — worth checking if "slow" coincides with a burst of
exports.

## How to verify this map against the live system

Don't trust a static map blindly — services and routing evolve. Confirm against
the running system:
- The **trace** is the authoritative dependency graph for a given request.
- The **gateway routing** is in api-gw's application config (URL pattern →
  backend).
- **Pulsar topic** names appear in both metrics (`pulsar_msg_backlog{topic=...}`)
  and consumer logs — use them to watch the async hops above.
