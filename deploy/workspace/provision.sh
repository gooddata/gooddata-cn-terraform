#!/usr/bin/env bash
set -euo pipefail

###
# Provision a test workspace on the deployed environment:
#   1. create a `testdata` database on the env's RDS and load the CSVs
#   2. register it as a POSTGRESQL data source in GoodData CN
#   3. scan the schema and generate the logical data model (LDM)
#   4. create the workspace and apply the LDM
#
# Prerequisites:
#   - data generated:    python3 gen_data.py [--orders 100000]
#   - kubectl configured: ../deploy.sh <env> kubectl
#   - psql installed (brew install libpq)
#
# Required env vars:
#   TIGER_ENDPOINT   e.g. https://gooddata.local-inference.dev11.devgdc.com
#   TIGER_API_TOKEN  org API token
#   PG_HOST          RDS endpoint (terraform output, or AWS console -> RDS)
#   PG_PASSWORD      master password; with kubectl configured:
#                    kubectl -n gooddata-cn get secret gooddata-cn-metadata-pg \
#                      -o jsonpath='{.data.password}' | base64 -d
#                    (secret name may differ per chart version — `kubectl -n
#                    gooddata-cn get secrets | grep -i pg` to locate it)
#
# Optional:
#   WORKSPACE_ID     default "sales-test"
#   DATA_DIR         default "./data"
###

: "${TIGER_ENDPOINT:?Set TIGER_ENDPOINT}"
: "${TIGER_API_TOKEN:?Set TIGER_API_TOKEN}"
: "${PG_HOST:?Set PG_HOST (RDS endpoint)}"
: "${PG_PASSWORD:?Set PG_PASSWORD (RDS master password)}"

WORKSPACE_ID="${WORKSPACE_ID:-sales-test}"
DATA_DIR="${DATA_DIR:-./data}"
DS_ID="testdata-pg"
PG_USER="postgres"
PG_DB="testdata"

AUTH=(-H "Authorization: Bearer $TIGER_API_TOKEN")
JSON=(-H "Content-Type: application/vnd.gooddata.api+json")

echo ">> 1/4 Creating database '$PG_DB' and loading data"
PGPASSWORD="$PG_PASSWORD" psql -h "$PG_HOST" -U "$PG_USER" -d postgres \
    -tc "SELECT 1 FROM pg_database WHERE datname = '$PG_DB'" | grep -q 1 \
    || PGPASSWORD="$PG_PASSWORD" psql -h "$PG_HOST" -U "$PG_USER" -d postgres -c "CREATE DATABASE $PG_DB"

PGPASSWORD="$PG_PASSWORD" psql -h "$PG_HOST" -U "$PG_USER" -d "$PG_DB" <<SQL
DROP TABLE IF EXISTS orders; DROP TABLE IF EXISTS customers; DROP TABLE IF EXISTS products;
CREATE TABLE customers (customer_id INT PRIMARY KEY, customer_name TEXT, region TEXT, country TEXT, segment TEXT);
CREATE TABLE products  (product_id INT PRIMARY KEY, product_name TEXT, category TEXT, unit_price NUMERIC(10,2));
CREATE TABLE orders    (order_id INT PRIMARY KEY, order_date DATE, customer_id INT REFERENCES customers,
                        product_id INT REFERENCES products, channel TEXT, status TEXT,
                        quantity INT, revenue NUMERIC(12,2), discount_pct INT);
SQL
for t in customers products orders; do
    PGPASSWORD="$PG_PASSWORD" psql -h "$PG_HOST" -U "$PG_USER" -d "$PG_DB" \
        -c "\copy $t FROM '$DATA_DIR/$t.csv' WITH (FORMAT csv, HEADER true)"
done

echo ">> 2/4 Registering data source '$DS_ID'"
curl -sf "${AUTH[@]}" "${JSON[@]}" -X DELETE "$TIGER_ENDPOINT/api/v1/entities/dataSources/$DS_ID" -o /dev/null -w "   DELETE old: %{http_code}\n" || true
curl -sf "${AUTH[@]}" "${JSON[@]}" -X POST "$TIGER_ENDPOINT/api/v1/entities/dataSources" -d "{
  \"data\": {\"id\": \"$DS_ID\", \"type\": \"dataSource\", \"attributes\": {
    \"name\": \"Test data (RDS)\", \"type\": \"POSTGRESQL\",
    \"url\": \"jdbc:postgresql://$PG_HOST:5432/$PG_DB\",
    \"schema\": \"public\", \"username\": \"$PG_USER\", \"password\": \"$PG_PASSWORD\"
  }}}" -o /dev/null -w "   CREATE: %{http_code}\n"

echo ">> 3/4 Generating LDM from schema scan"
LDM=$(curl -sf "${AUTH[@]}" "${JSON[@]}" -X POST \
    "$TIGER_ENDPOINT/api/v1/actions/dataSources/$DS_ID/generateLogicalModel" \
    -d '{"separator": "__", "generateLongIds": false, "tableNames": ["customers","products","orders"], "primaryLabelPrefix": "id", "secondaryLabelPrefix": "ls", "factPrefix": "f", "datePrefix": "dt", "grainPrefix": "gr", "referencePrefix": "r", "denormPrefix": "dn", "wdfPrefix": "wdf"}')

echo ">> 4/4 Creating workspace '$WORKSPACE_ID' and applying LDM"
curl -sf "${AUTH[@]}" "${JSON[@]}" -X DELETE "$TIGER_ENDPOINT/api/v1/entities/workspaces/$WORKSPACE_ID" -o /dev/null -w "   DELETE old: %{http_code}\n" || true
curl -sf "${AUTH[@]}" "${JSON[@]}" -X POST "$TIGER_ENDPOINT/api/v1/entities/workspaces" \
    -d "{\"data\": {\"id\": \"$WORKSPACE_ID\", \"type\": \"workspace\", \"attributes\": {\"name\": \"Sales test\"}}}" \
    -o /dev/null -w "   CREATE: %{http_code}\n"
# generateLogicalModel returns the declarative LDM; the layout PUT expects it
# wrapped under "ldm" (already is in current API versions — normalize anyway)
echo "$LDM" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(json.dumps(d if 'ldm' in d else {'ldm': d}))" > /tmp/ldm.json
curl -sf "${AUTH[@]}" -H "Content-Type: application/json" -X PUT \
    "$TIGER_ENDPOINT/api/v1/layout/workspaces/$WORKSPACE_ID/logicalModel" \
    -d @/tmp/ldm.json -o /dev/null -w "   PUT LDM: %{http_code}\n"

echo ""
echo "Done. Open: $TIGER_ENDPOINT/analyze/#/$WORKSPACE_ID"
echo "AI chat will see datasets: customers, products, orders."
