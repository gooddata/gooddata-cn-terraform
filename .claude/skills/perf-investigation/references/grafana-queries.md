# Grafana query reference (Prometheus / Tempo / Loki)

Concrete query patterns for a GoodData.CN-style stack on Kubernetes, via the
Grafana MCP tools. Replace `NAMESPACE`, service/job names, and time bounds with
your own. These are starting points — adapt label names to what your cluster
actually exposes (use the metric/label discovery tools first if unsure).

Contents:
- Conventions and gotchas
- Prometheus — CPU, throttling, memory, latency, **backlog/queue depth**, pools
- Tempo — fetch + decompose a trace, find slow traces
- Loki — correlate by trace ID, read timing/backlog logs
- Reading source when a constant is opaque

## Conventions and gotchas

- **Datasource UIDs**: typically `prometheus`, `loki`, `tempo`. Confirm with the
  datasource-list tool if queries return nothing.
- **Time formats differ by tool.** Prometheus tools accept relative (`now-25m`)
  and RFC3339. Loki tools generally want **RFC3339** (`2026-06-10T14:30:00Z`) —
  `now-25m` will error. Tempo proxy search/lookup wants **unix seconds** for
  `start`/`end`. Convert with `date -u -d @<unix>` / `date -u +%s`.
- **Big results overflow.** A full trace or a wide log query can exceed the
  response limit. Prefer `jq`-filtered Tempo lookups and `count_over_time` /
  `| json | unwrap` Loki aggregations over dumping raw lines.
- **Find the load window first.** Most investigations start by locating the
  burst in the request-rate metric, then zooming every other query to it.

## Prometheus — the resource picture

Find the load window (request rate; idle baseline is low, a test/burst spikes):

```promql
sum(rate(http_server_requests_seconds_count{job=~".*<service>.*"}[1m]))
```

Per-pod CPU usage (compare against the pod's CPU *limit* to judge headroom):

```promql
sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="NAMESPACE", pod=~"<service>.*", container!=""}[2m]))
```

**CFS throttling ratio** — the critical companion to CPU. A pod can show low
*average* CPU yet be throttled in bursts; and a pod with idle CPU and ~0
throttling that is still slow is **not** CPU-bound (look for a concurrency
constant instead):

```promql
sum by (pod) (rate(container_cpu_cfs_throttled_periods_total{namespace="NAMESPACE", pod=~"<service>.*"}[2m]))
  / sum by (pod) (rate(container_cpu_cfs_periods_total{namespace="NAMESPACE", pod=~"<service>.*"}[2m]))
```

Memory working set vs. limit (catch OOM risk / pods near their ceiling):

```promql
max by (pod) (container_memory_working_set_bytes{namespace="NAMESPACE", pod=~"<service>.*", container!=""}) / 1024 / 1024
kube_pod_container_resource_limits{namespace="NAMESPACE", pod=~"<service>.*", resource="memory"} / 1024 / 1024
```

Per-endpoint latency (mean over the window; swap `_sum`/`_count` for a
histogram quantile if buckets exist):

```promql
sum by (uri) (rate(http_server_requests_seconds_sum{job=~".*<service>.*"}[3m]))
  / sum by (uri) (rate(http_server_requests_seconds_count{job=~".*<service>.*"}[3m]))
```

gRPC server-side latency (service-to-service hops):

```promql
sum by (method) (rate(grpc_server_call_duration_seconds_sum{job=~".*<service>.*"}[3m]))
  / sum by (method) (rate(grpc_server_call_duration_seconds_count{job=~".*<service>.*"}[3m]))
```

**Queue / backlog depth** — where work piles up. For async hops via Pulsar.

The **unacked-message backlog** is a frequent, non-obvious cause of slowdown:
these are messages delivered to a consumer that were never acknowledged (the
consumer is stuck mid-processing or blocked on its own downstream), so the work
shows up in *neither* CPU nor request-rate while everything queued behind it
stalls. Check it early and across **all** topics, not just the one you suspect:

```promql
sum(pulsar_consumer_unacked_messages{cluster_name=~"$cluster", topic=~"persistent://${ns}/.*"}) by (topic)
```

Plain backlog (messages not yet delivered) and the per-subscription view:

```promql
sum by (topic) (pulsar_msg_backlog{topic=~".*<topic>.*"})
sum by (topic) (pulsar_subscription_unacked_messages{topic=~".*<topic>.*"})
```

A topic whose unacked count climbs while its consumer service sits at low CPU is
the async equivalent of the signature-table's "victim" row: the consumer is
blocked downstream, not slow itself — follow its next hop.

Connection-pool saturation (e.g. JDBC/Hikari) — active pinned at the max with
pending > 0 means the pool size is the gate:

```promql
sum by (pod) (hikaricp_connections_active{namespace="NAMESPACE", pod=~"<service>.*"})
sum by (pod) (hikaricp_connections_pending{namespace="NAMESPACE", pod=~"<service>.*"})
```

Any service-specific in-flight / active-request gauge is gold for Little's law
(active requests vs. CPU vs. latency). Discover them with the metric-name search
tool (look for `*active*`, `*queue*`, `*in_progress*`, `*backpressure*`).

## Tempo — where the wall-clock goes

Fetch a trace by ID via the Grafana → Tempo datasource proxy, and **decompose
it into a span timeline** (offset from root + duration), which is the single
most useful artifact in the whole investigation:

```
GET /api/datasources/proxy/uid/tempo/api/traces/<TRACE_ID>?start=<unixSec>&end=<unixSec>
```

`jq` to turn the raw trace into an ordered timeline (`+offsetms [durationms]
service span`):

```jq
[.batches[]
 | (.resource.attributes[]? | select(.key=="service.name") | .value.stringValue) as $svc
 | .scopeSpans[].spans[]
 | {svc:$svc, name:.name[0:60],
    start:(.startTimeUnixNano|tonumber/1e9),
    durMs:(((.endTimeUnixNano|tonumber)-(.startTimeUnixNano|tonumber))/1e6|floor)}]
| sort_by(.start)
| (.[0].start) as $t0
| .[] | "+\(((.start-$t0)*1000)|floor)ms [\(.durMs)ms] \(.svc) \(.name)"
```

Interpret the timeline as in SKILL.md step 4: find the span that owns the
wall-clock, then decide whether its time is self-time (a gap with no covering
children → computing or blocked) or inside children (→ follow the child
downstream).

Find slow traces in a window (TraceQL, when you have a time range but no ID):

```
GET /api/datasources/proxy/uid/tempo/api/search?q=<TraceQL>&start=<unixSec>&end=<unixSec>&limit=10

# TraceQL examples (URL-encode):
{ resource.service.name="<service>" && duration>8s }
{ resource.service.name="<service>" && name=~".*<endpoint>.*" && duration>5s }
```

Tempo's recent-window search can lag a minute or two; if a just-finished run
returns nothing, widen the window slightly or retry.

## Loki — correlate and read the timing logs

Correlate everything for one request by trace ID (services usually log
`traceId`):

```logql
{namespace="NAMESPACE"} |= "<TRACE_ID>" | json
  | line_format "{{.ts}} {{.pod}} {{.action}} {{.msg}}"
```

Count a recurring event over the window (e.g. timeouts, evictions, retries) —
use a metric query, not a raw dump:

```logql
sum(count_over_time({namespace="NAMESPACE", pod=~"<service>.*"} |~ "<error pattern>" [1m]))
```

Extract a numeric field a service logs (queue wait, in-service duration, bytes)
and aggregate it — this is how you confirm "compute was Xms but the task waited
Ns":

```logql
avg(avg_over_time({namespace="NAMESPACE", pod=~"<service>.*"} |= "<marker>" | json | unwrap <numeric_field> [1m]))
```

Pull the peer/target a stalled call was waiting on (regex out an IP/host to see
whether all timeouts point at **one** node — a hot-shard signature):

```logql
{namespace="NAMESPACE", pod=~"<service>.*"} |~ "<timeout marker>"
  | regexp "peer ipv4:(?P<peer>[0-9.]+)" | line_format "{{.peer}}"
```

If a single peer owns ~100% of the timeouts while that node has idle CPU, you're
looking at a per-node coordination/hot-shard ceiling, not a sizing problem.

## Reading source when a constant is opaque

When you suspect a hardcoded concurrency constant but can't find its value or
override, the image is often public. Pull it and read the real default and the
env-var convention rather than guessing:

```bash
docker pull <registry>/<image>:<tag>
docker create --name tmp <registry>/<image>:<tag>
docker export tmp | tar -x -C ./rootfs --wildcards '*<relevant-path>*'
# then grep the source/config for the default and its env override
```

This turns "I think the pool is small" into "it's N, overridable via `<ENV_VAR>`"
— the difference between a guess and a fix. The value being *knowable* is the
point, not any particular number.
