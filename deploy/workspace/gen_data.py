#!/usr/bin/env python3
"""Generate a synthetic star schema as CSVs for workspace testing.

Deterministic (seeded) — same scale always produces the same data, so AI
answers are comparable across runs. Scale up for "bigger testing":

    python3 gen_data.py --orders 100000 --customers 5000 --products 500

Output: customers.csv, products.csv, orders.csv in --out-dir (default ./data).
Load with provision.sh (psql \\copy into the env's RDS).
"""

import argparse
import csv
import random
from datetime import date, timedelta
from pathlib import Path

REGIONS = ["EMEA", "AMER", "APAC"]
COUNTRIES = {
    "EMEA": ["Germany", "Czechia", "France", "UK", "Netherlands"],
    "AMER": ["USA", "Canada", "Brazil", "Mexico"],
    "APAC": ["Japan", "Australia", "Singapore", "India"],
}
SEGMENTS = ["Enterprise", "Mid-Market", "SMB"]
CATEGORIES = ["Analytics", "Storage", "Compute", "Networking", "Security"]
CHANNELS = ["Direct", "Partner", "Online"]
STATUSES = ["Completed", "Returned", "Cancelled"]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--orders", type=int, default=10_000)
    parser.add_argument("--customers", type=int, default=500)
    parser.add_argument("--products", type=int, default=100)
    parser.add_argument("--out-dir", default="data")
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    rng = random.Random(args.seed)
    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)

    with open(out / "customers.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["customer_id", "customer_name", "region", "country", "segment"])
        for i in range(1, args.customers + 1):
            region = rng.choice(REGIONS)
            w.writerow([i, f"Customer {i:05d}", region, rng.choice(COUNTRIES[region]), rng.choice(SEGMENTS)])

    with open(out / "products.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["product_id", "product_name", "category", "unit_price"])
        for i in range(1, args.products + 1):
            w.writerow([i, f"Product {i:04d}", rng.choice(CATEGORIES), round(rng.uniform(10, 2000), 2)])

    start = date(2024, 1, 1)
    days = (date(2026, 6, 1) - start).days
    with open(out / "orders.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["order_id", "order_date", "customer_id", "product_id", "channel", "status", "quantity", "revenue", "discount_pct"])
        for i in range(1, args.orders + 1):
            qty = rng.randint(1, 50)
            price = round(rng.uniform(10, 2000), 2)
            discount = rng.choice([0, 0, 0, 5, 10, 15, 25])
            revenue = round(qty * price * (1 - discount / 100), 2)
            w.writerow([
                i,
                (start + timedelta(days=rng.randint(0, days))).isoformat(),
                rng.randint(1, args.customers),
                rng.randint(1, args.products),
                rng.choice(CHANNELS),
                rng.choices(STATUSES, weights=[90, 6, 4])[0],
                qty,
                revenue,
                discount,
            ])

    print(f"Generated {args.customers} customers, {args.products} products, {args.orders} orders -> {out}/")


if __name__ == "__main__":
    main()
