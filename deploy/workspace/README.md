# Test workspace & data

Three tiers, smallest first — all keep data **inside our VPC** (the env's RDS),
consistent with the sovereignty story:

| Tier | Source | When |
|---|---|---|
| 1. Synthetic star schema | `gen_data.py` + `provision.sh` (this dir) | now — pipeline + AI answer testing |
| 2. Scaled-up synthetic | same, `--orders 1000000` | bigger testing; bump RDS first (below) |
| 3. QA Mastercard-like workspace | QA team ticket (multi-tenant, complex LDM) | when delivered — the real M1 dataset |

A Tomkess demo (`gd-manufacturing-demo`, `gd-telco-demo`, …) can be layered on
top later for richer analytics layouts — they are declarative-API provisioners
and work against any org.

## Quick start (tier 1)

```bash
python3 gen_data.py                       # 10k orders, 500 customers, 100 products
export TIGER_ENDPOINT=https://gooddata.local-inference.dev11.devgdc.com
export TIGER_API_TOKEN=<org token>
export PG_HOST=<rds endpoint>             # AWS console -> RDS -> local-inference
export PG_PASSWORD=<master password>      # see provision.sh header for kubectl one-liner
./provision.sh
```

Creates the `testdata` DB on RDS, loads CSVs, registers the data source,
scan-generates the LDM, and creates workspace `sales-test`. AI chat then has
real datasets (orders/customers/products) to answer against — revenue by
region, top products, returns by channel, …

## Bigger testing (tier 2)

- Regenerate at scale: `python3 gen_data.py --orders 1000000 --customers 20000`
  (~100 MB CSV; deterministic seed → comparable AI answers across runs)
- **Bump RDS first** in `deploy/envs/local-inference/settings.tfvars`:
  `rds_instance_class = "db.t4g.large"` — the metadata DB shares the instance;
  20 GB storage holds ~10M orders fine, the constraint is CPU during loads
  and concurrent analytics queries.
- Re-run `provision.sh` (drops & reloads tables idempotently).

## Real data ("pořádná data")

For customer-like data (DATEV/Mark43 shape), load into the same `testdata` DB
or a dedicated one — never an external SaaS DB, the point is that nothing
leaves the VPC. If the dataset needs more than RDS comfortably serves,
that's the moment to revisit StarRocks (`enable_ai_lake`) — not before.
