---
name: perf-investigation
description: Use when investigating a performance problem in a deployed GoodData.CN (or similar multi-service Kubernetes platform) from observability data — slow dashboard/report loads, high latency, throughput that collapses under load, a request "stuck" somewhere, or a specific slow trace. Triggers include a trace ID with "why is this taking so long", a time-bounded report ("loading was slow ~10 minutes ago"), p95/latency regressions, "stuck in <service>", or queues/backlogs building. Drives a systematic root-cause investigation with Grafana metrics, logs, and traces — finds the true bottleneck, proves it with evidence, and names the correct fix. Use it even when the user hasn't named a specific service.
---

# Performance investigation

You are handed a symptom — a slow trace, or "X was slow at time T" — and asked
why. This skill is the method for answering that **from observability data**,
without guessing.

The single most important idea: **the symptom is rarely where the cause is.** A
queue piling up on service A usually means A is blocked waiting on a slow
service B downstream. So resist the urge to "fix" the service the user named.
Find where the wall-clock time actually goes, prove it, and only then act.

## When to use

- A trace is slow and you need to know why ("trace `abc123` took 13s").
- A time-bounded slowness report ("dashboards were slow around 14:30").
- A latency/throughput regression, a request "stuck" in a service, or a
  Pulsar/queue/consumer backlog building under load.

**Do not use** for: writing load tests (this is post-hoc diagnosis), pure
front-end/browser performance with no backend traces, or a one-off "is the
cluster up" health check.

## Prerequisites

You need read access to the observability stack — Grafana with Prometheus
(metrics), Loki (logs), and Tempo (traces), typically via the Grafana MCP
tools. Read-only `kubectl` helps for pod/limit context. You do **not** need to
change anything to diagnose; treat the investigation as read-only until you
have proof and a named fix.

## The investigation loop

Work this in order. Each step narrows the search; don't skip ahead to a fix.

### 1. Pin the symptom precisely

Get a concrete anchor before touching any tool:
- A **trace ID**, or
- A **time window** (start/end) and **what** was slow (which endpoint / user
  action), and **how slow** (p95? a single 30s outlier?).

**If the anchor is ambiguous, ask the user — don't guess.** Use the
AskUserQuestion tool to nail down the things only they know before you spend the
investigation on the wrong target. The questions worth asking are usually:

- **When** exactly (timezone-explicit), and is this a **one-off outlier or a
  sustained/recurring** slowdown? (A 30s tail and a 30s p95 are different
  problems.)
- **What** action/endpoint — which dashboard, report, or API call — and from
  one user or many?
- **How slow vs. normal**, and **is it still happening** now or already over?
- Was there a **recent change** (deploy, config, data volume, new tenant) that
  lines up with onset?

Derive cheaply what the data can tell you — the load burst from the
request-rate metric, the slow endpoint from a slow-span search. Ask the user
only for what the data can't: which action they mean, whether it's chronic,
what "slow" means to them, what changed. One round of questions up front beats
analyzing the wrong window. Vague symptom → vague investigation.

### 2. Reproduce the evidence — do not theorize first

Pull the actual data for that anchor before forming any theory (query patterns
in [references/grafana-queries.md](references/grafana-queries.md)):
- If you have a trace ID: fetch and **decompose the trace** (step 4).
- If you have a window: find the slow traces in it (by service + minimum
  duration), and pull per-service latency plus queue/backlog metrics — including
  the Pulsar **unacked**-message backlog, a frequent and non-obvious culprit:
  work delivered to a consumer but never finished shows up in neither CPU nor
  request rate, yet stalls everything waiting behind it.

### 3. Map the request path (discover it, don't assume)

You need the service dependency chain to reason about cause vs. victim. Derive
it from the evidence rather than memory:
- The trace itself is the dependency graph — parent/child spans across services
  show who calls whom.
- The gateway's routing config maps URL patterns → backend services.
- Service-to-service calls show up as client spans and gRPC/HTTP metrics.

Note which hops are synchronous (caller blocks) vs. asynchronous (queue/topic
hand-off) — the bottleneck behaves very differently in each. A slow synchronous
downstream shows up as **latency and held connections** on the caller; a slow
async consumer shows up as a **topic backlog**, not caller latency.

For the GoodData.CN request flow specifically — the gateway routing table (slow
URL → which backend owns it) and the AFM execution chain annotated with where
each bottleneck class tends to live (the forward pool, the cache hit/miss fork,
the `sql.select` / `result.xtab` async hops, the cross-tab and result-fetch
stages) — read [references/request-flow.md](references/request-flow.md). It's
the fast way to know which service a slow endpoint implicates before you open a
single trace. Still confirm against the live trace; the map orients you, the
trace proves it.

### 4. Localize: where does the wall-clock actually go?

This is the heart of it. **Decompose the slow trace into a span timeline** —
for each span, its start offset relative to the root and its duration. Then ask
of the span that dominates the wall-clock:

- Is the time **inside its own self-time** (a gap with no active children)? →
  the service is either computing, or **blocked waiting** (on a lock, a
  connection, a downstream response it hasn't received yet, or a queue slot).
- Is the time **inside child spans**? → the cost is downstream; follow the
  child. The named service is a **conduit**, not the cause.

A decisive tell: a span lasting seconds whose actual unit of work (the compute
you can find in logs) is milliseconds is **waiting**, not working. That rules
out "needs a faster CPU" and points at a queue, a connection pool, or a
downstream stall.

For a time-window report without one trace, do the same with metrics: per-hop
latency over the window tells you which hop's latency rose; the queue/backlog
metrics tell you where work piled up.

### 5. Classify the bottleneck (the signature table)

Once you know *which* service/hop owns the time, classify *why* using its CPU,
throttling, queue depth, and latency together. This table is the most reusable
part of the skill:

| What you observe | Most likely cause | Right lever | Wrong lever (won't help) |
|---|---|---|---|
| **Idle CPU + deep queue + high latency** | A hardcoded **concurrency constant** capping in-flight work | Raise the constant (often a buried env var / pool size) | Add CPU or replicas |
| **High CPU / CFS-throttled** | Genuine compute/resource shortage | More CPU limit, or scale out | Raising pool sizes (makes contention worse) |
| **Queue on X, but X idle and its span time is in a downstream child** | X is a **victim** of a slow downstream | Fix the downstream gate | Scaling X |
| **Idle CPU, can't keep up, no constant left to raise** — e.g. many clients' timeouts all point at one peer node that itself has spare CPU | An **architectural ceiling**: single-threaded loop, hot shard owned by one node, or strict-consistency gate | Code/architecture change or upstream report | More CPU/replicas/pods |
| **DB/connection-acquire waits, app threads idle** | Connection-pool / acquire-timeout limit | Raise pool size (and check the DB can take it) | App CPU/replicas |
| **Burstable instance, latency cliff after minutes** | Exhausted CPU credits (cloud burstable tier) | Non-burstable instance class | More app-side tuning |

The first row is common and the easiest to misread as a CPU/replica shortage.
Small concurrency constants — thread-pool sizes, an HTTP client's per-route
connection pool, a JDBC/Hikari pool, a worker/subprocess count, a coroutine
dispatcher cap, a message-consumer prefetch — throttle a service that then sits
at low CPU while requests queue. The instinct to "add pods" is usually wrong
here; the fix is raising the number.

### 6. Prove it before recommending a fix

A plausible story is not a proven one. Confirm with at least one hard check:

- **Trace decomposition** already localized the time; confirm the dominant
  span's time is self vs. child as you claimed.
- **Little's law** turns queue depth into effective concurrency:
  `L = λ × W` → effective concurrency `= throughput × mean-in-service-time`.
  If that sits at a stable integer ceiling well below CPU saturation, that
  ceiling is almost certainly a configured limit — then go find which one.
- **Read the source / config defaults.** When a constant is opaque, the
  container image is often public — pull it and read the real default and its
  env-var override instead of guessing (commands in
  [references/grafana-queries.md](references/grafana-queries.md)).
- **Correlate logs by trace/ID** to see the per-stage timing the spans don't
  capture (e.g., a "waited Ns for a slot" or "queue depth N" log line).

If you cannot produce one of these, you have a hypothesis, not a root cause —
say so.

### 7. Name the fix and its lever class

State the fix as: *which constant/resource, on which service, changed from what
to what, and why that's the right lever class* (concurrency constant vs. CPU vs.
replicas vs. architecture). If it's an architectural ceiling (step 5, row 4),
say plainly that no sizing knob fixes it and what the real fix is (a code change
or an upstream issue), rather than recommending tuning that you've proven won't
help.

**Before declaring an architectural ceiling, check the load is realistic.** A
synthetic shape concentrated on one tenant, key, or shard — which production
rate-limits or spreads — can manufacture a ceiling real traffic never hits.
Confirm the traffic shape is representative before you burn effort on what may
be an artifact.

## Discipline that keeps you honest

Skipping these is how investigations go in circles for days.

- **Pre-register hypotheses.** Before any change, write the competing
  hypotheses and their predictions: "If it's the connection pool (H1), raising
  it drops p95 and the queue clears. If it's a downstream stall (H2), raising it
  changes nothing." Then the next test is decisive instead of ambiguous.
- **Change one variable at a time.** Bundling three changes means a green (or
  red) result tells you nothing about which one mattered. The temptation to fix
  everything at once destroys attribution.
- **Beware environmental drift.** If a known-good config stops reproducing the
  old result, suspect the environment moved, not just the config — a service
  OOM'd and recovered, a database was resized, a cache grew, a catalog
  accumulated.
- **Watch for the bottleneck *moving*.** Each fix often exposes the next gate.
  That's progress, but name it: "this is a new bottleneck, one hop down," not "the
  fix didn't work." Re-run the loop from step 4 on the new symptom.

## Tool reference

Concrete query patterns for Prometheus (CPU, throttling, queue depth),
Tempo (fetch + decompose a trace, find slow traces), and Loki (correlate by
trace ID, read backlog/wait logs) are in
[references/grafana-queries.md](references/grafana-queries.md). Read it when you
need the exact queries; the method above is what matters first.
