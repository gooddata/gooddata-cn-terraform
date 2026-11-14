#!/usr/bin/env bash
set -euo pipefail

# Scan every container image that runs in the cluster for CVEs and report which
# images come from a hardened source. Uses kubectl and trivy.
# Run `./scan-images.sh --help` for the options.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

# Registry prefixes that count as "hardened". Edit this list to fit your setup.
# An image is hardened when its reference starts with one of these prefixes.
HARDENED_PREFIXES=(
  "dhi.io/"
  "cgr.dev/chainguard/"
  "registry1.dso.mil/"
)
# Extra prefixes: HARDENED_EXTRA_PREFIXES="registry.example.com/ other.io/hardened/" (space or comma separated).
if [[ -n "${HARDENED_EXTRA_PREFIXES:-}" ]]; then
  read -r -a _extra <<<"${HARDENED_EXTRA_PREFIXES//,/ }"
  HARDENED_PREFIXES+=("${_extra[@]}")
fi

# Registries for which the script looks up a DHI OpenVEX attestation.
VEX_HOST="dhi.io"

SEVERITY="CRITICAL,HIGH,MEDIUM,LOW,UNKNOWN"
IGNORE_UNFIXED=0
JOBS=4
OUTPUT_FORMAT="table"
FAIL_ON_NON_HARDENED=0
NO_VEX=0
IMAGES_FILE=""
ARCH=""
KUBECTL_ARGS=()

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Scan all images that run in the cluster with trivy and print a table:
image, hardened (yes/no), critical, high and total CVE counts.
Counts are after the DHI VEX is applied (dhi.io images only).

Options:
  --kubeconfig <path>      Use this kubeconfig (default: KUBECONFIG or ~/.kube/config)
  --context <name>         Use this kubectl context
  --images-file <file>     Scan the images in <file> (one per line); skip the cluster
  --severity <list>        Severities counted in the total
                           (default: ${SEVERITY})
  --ignore-unfixed         Ignore CVEs that have no fix
  -j, --jobs <n>           Parallel trivy scans (default: ${JOBS})
  --arch <amd64|arm64>     Platform for scan and VEX lookup (default: this host)
  --no-vex                 Do not fetch or apply the DHI VEX
  --json                   Print JSON instead of a table
  --csv                    Print CSV instead of a table
  --fail-on-non-hardened   Exit with code 2 if any image is not hardened
  -h, --help               Show this help

Environment:
  DHI_USERNAME, DHI_TOKEN  Credentials for dhi.io. Without them, the script uses
                           your existing \`docker login\` (DOCKER_CONFIG).
  TRIVY_USERNAME, TRIVY_PASSWORD  Credentials trivy uses for other registries.

  HARDENED_EXTRA_PREFIXES  Extra hardened registry prefixes, space or comma separated
                           (for example "registry.example.com/hardened/").

Hardened sources (edit HARDENED_PREFIXES in the script):
USAGE
  printf '  %s\n' "${HARDENED_PREFIXES[@]}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig) KUBECTL_ARGS+=(--kubeconfig "${2:?--kubeconfig needs a value}"); shift 2 ;;
    --context) KUBECTL_ARGS+=(--context "${2:?--context needs a value}"); shift 2 ;;
    --images-file) IMAGES_FILE="${2:?--images-file needs a value}"; shift 2 ;;
    --severity) SEVERITY="${2:?--severity needs a value}"; shift 2 ;;
    --ignore-unfixed) IGNORE_UNFIXED=1; shift ;;
    -j|--jobs) JOBS="${2:?--jobs needs a value}"; shift 2 ;;
    --arch) ARCH="${2:?--arch needs a value}"; shift 2 ;;
    --no-vex) NO_VEX=1; shift ;;
    --json) OUTPUT_FORMAT="json"; shift ;;
    --csv) OUTPUT_FORMAT="csv"; shift ;;
    --fail-on-non-hardened) FAIL_ON_NON_HARDENED=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown option '$1'. Use --help." >&2; exit 1 ;;
  esac
done

if ! [[ "${JOBS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: --jobs must be a positive integer." >&2
  exit 1
fi

require_command trivy "trivy not found; install it from https://trivy.dev to scan images."
require_command jq "jq not found; install it to read scan results."
if [[ -z "${IMAGES_FILE}" ]]; then
  require_command kubectl "kubectl not found; install it to list cluster images."
else
  [[ -r "${IMAGES_FILE}" ]] || { echo "Error: cannot read ${IMAGES_FILE}." >&2; exit 1; }
fi

if [[ -z "${ARCH}" ]]; then
  case "$(uname -m)" in
    aarch64|arm64) ARCH=arm64 ;;
    *) ARCH=amd64 ;;
  esac
fi

WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT
log() { echo ">> $*" >&2; }

# --- Step 1: list images -----------------------------------------------------
# Output lines: "<image>\t<digest or empty>". One line per unique image.
list_cluster_images() {
  kubectl "${KUBECTL_ARGS[@]+"${KUBECTL_ARGS[@]}"}" get pods --all-namespaces -o json |
    jq -r '
      .items[] |
      ( [ (.spec.containers[]?, .spec.initContainers[]?, .spec.ephemeralContainers[]?) | {key: .name, value: .image} ] | from_entries ) as $spec |
      ( [ (.status.containerStatuses[]?, .status.initContainerStatuses[]?, .status.ephemeralContainerStatuses[]?)
          | {key: .name, value: (.imageID // "")} ] | from_entries ) as $ids |
      ( $spec | to_entries[] ) |
      "\(.value)\t\((($ids[.key] // "") | capture("(?<d>sha256:[a-f0-9]{64})$") | .d) // "")"
    ' | sort -u
}

if [[ -n "${IMAGES_FILE}" ]]; then
  log "Reading images from ${IMAGES_FILE}."
  # Tolerate comments and blank lines. A line may be "image" or "image@sha256:...".
  { grep -vE '^[[:space:]]*(#|$)' "${IMAGES_FILE}" || true; } | awk '{print $1}' | sort -u |
    awk '{ d=""; if (match($0, /@sha256:[a-f0-9]{64}$/)) d=substr($0, RSTART+1); print $0 "\t" d }' >"${WORK_DIR}/raw.tsv"
else
  log "Listing images in all namespaces..."
  list_cluster_images >"${WORK_DIR}/raw.tsv"
fi

# De-duplicate by image string; keep the first non-empty digest.
awk -F'\t' '{ if (!($1 in d) || d[$1]=="") d[$1]=$2; if (!($1 in o)) { o[$1]=++n; k[n]=$1 } }
  END { for (i=1;i<=n;i++) print k[i] "\t" d[k[i]] }' "${WORK_DIR}/raw.tsv" >"${WORK_DIR}/images.tsv"

IMAGE_COUNT=$(wc -l <"${WORK_DIR}/images.tsv" | tr -d ' ')
if [[ "${IMAGE_COUNT}" -eq 0 ]]; then
  echo "Error: no images found." >&2
  exit 1
fi
log "Found ${IMAGE_COUNT} unique images."

# --- Registry auth -----------------------------------------------------------
# Use a private DOCKER_CONFIG copy so DHI_USERNAME/DHI_TOKEN never touch the
# user's real config. Trivy and crane both read it. Secrets are not printed.
setup_auth() {
  local base="${DOCKER_CONFIG:-${HOME}/.docker}/config.json"
  mkdir -p "${WORK_DIR}/docker"
  if [[ -r "${base}" ]]; then
    cp "${base}" "${WORK_DIR}/docker/config.json"
  else
    echo '{}' >"${WORK_DIR}/docker/config.json"
  fi
  if [[ -n "${DHI_USERNAME:-}" && -n "${DHI_TOKEN:-}" ]]; then
    local auth
    auth=$(printf '%s:%s' "${DHI_USERNAME}" "${DHI_TOKEN}" | base64 | tr -d '\n')
    jq --arg h "${VEX_HOST}" --arg a "${auth}" '.auths[$h] = {auth: $a}' \
      "${WORK_DIR}/docker/config.json" >"${WORK_DIR}/docker/config.new"
    mv "${WORK_DIR}/docker/config.new" "${WORK_DIR}/docker/config.json"
    log "Using DHI_USERNAME/DHI_TOKEN for ${VEX_HOST}."
  fi
  chmod 600 "${WORK_DIR}/docker/config.json"
  export DOCKER_CONFIG="${WORK_DIR}/docker"
}
setup_auth

# --- DHI VEX -----------------------------------------------------------------
# Adapted from the DHI VEX spike tool: fetch the OpenVEX attestation (a referrer
# of the platform manifest), keep the not_affected statements, and write a file
# that trivy accepts with --vex.
fetch_vex() {
  local ref="$1" out="$2"
  python3 -I - "${ref}" "${ARCH}" "${out}" <<'PY'
import json, subprocess, sys, urllib.parse, urllib.request
ref, arch, out = sys.argv[1:4]
host, _, rest = ref.partition("/")
repo = rest.split("@")[0]
tag = rest.split("@", 1)[1] if "@" in rest else (repo.rsplit(":", 1)[1] if ":" in repo.rsplit("/", 1)[-1] else "latest")
if ":" in repo.rsplit("/", 1)[-1]:
    repo = repo.rsplit(":", 1)[0]
tok = json.loads(subprocess.run(["crane", "auth", "token", f"{host}/{repo}"], capture_output=True, text=True, check=True).stdout)["token"]
def get(path, accept):
    req = urllib.request.Request(f"https://{host}/v2/{repo}{path}", headers={"Authorization": "Bearer " + tok, "Accept": accept})
    return urllib.request.urlopen(req, timeout=60).read()
idx = json.loads(get(f"/manifests/{tag}", "application/vnd.oci.image.index.v1+json"))
plat = [m["digest"] for m in idx["manifests"] if m.get("platform", {}).get("architecture") == arch][0]
refs = json.loads(get(f"/referrers/{plat}", "application/vnd.oci.image.index.v1+json"))["manifests"]
vex = [m["digest"] for m in refs if "openvex" in m.get("annotations", {}).get("in-toto.io/predicate-type", "")][0]
layer = json.loads(get(f"/manifests/{vex}", "application/vnd.oci.image.manifest.v1+json"))["layers"][0]["digest"]
pred = json.loads(get(f"/blobs/{layer}", "*/*"))["predicate"]
stmts = []
for s in pred["statements"]:
    if s["status"] != "not_affected":
        continue
    prods = set()
    def walk(o):
        if isinstance(o, dict):
            for k, v in o.items():
                if k in ("@id", "purl") and isinstance(v, str) and v.startswith("pkg:"):
                    prods.add(urllib.parse.unquote(v.split("?")[0]))
                walk(v)
        elif isinstance(o, list):
            for x in o:
                walk(x)
    walk(s)
    t = dict(s)
    t["products"] = [{"@id": p} for p in sorted(prods)]
    t.pop("subcomponents", None)
    stmts.append(t)
pred["statements"] = stmts
json.dump(pred, open(out, "w"))
PY
}

# --- Per-image helpers -------------------------------------------------------
is_hardened() {
  local image="$1" p
  for p in "${HARDENED_PREFIXES[@]}"; do
    [[ "${image}" == "${p}"* ]] && return 0
  done
  return 1
}

# Strip tag and digest: "dhi.io/x:1.2@sha256:..." -> "dhi.io/x".
image_repo() {
  local r="${1%%@*}"
  local last="${r##*/}"
  if [[ "${last}" == *:* ]]; then
    r="${r%:*}"
  fi
  echo "${r}"
}

: >"${WORK_DIR}/jobs.tsv"
idx=0
if [[ "${NO_VEX}" -eq 0 ]] && ! command_exists crane; then
  warn "crane not found; scanning without the DHI VEX."
  NO_VEX=1
fi
while IFS=$'\t' read -r image digest; do
  idx=$((idx + 1))
  target="${image}"
  [[ -n "${digest}" && "${image}" != *@sha256:* ]] && target="$(image_repo "${image}")@${digest}"
  hardened=no
  is_hardened "${image}" && hardened=yes
  vexfile=""
  if [[ "${NO_VEX}" -eq 0 && "${image}" == "${VEX_HOST}/"* ]]; then
    if fetch_vex "${image}" "${WORK_DIR}/vex-${idx}.json" 2>"${WORK_DIR}/vex-${idx}.err"; then
      vexfile="${WORK_DIR}/vex-${idx}.json"
    else
      warn "DHI VEX not available for ${image}; scanning without VEX."
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "${idx}" "${image}" "${target}" "${hardened}" "${vexfile}" >>"${WORK_DIR}/jobs.tsv"
done <"${WORK_DIR}/images.tsv"

# --- Step 2: scan in parallel ------------------------------------------------
SKIP_DB_ARGS=()
log "Updating the trivy vulnerability database..."
if trivy image --download-db-only >/dev/null 2>&1; then
  SKIP_DB_ARGS=(--skip-db-update)
else
  warn "Could not update the trivy database; scans may fail or use a stale cache."
fi

# Run trivy once. $1 = idx, $2 = target, $3 = vexfile, $4 = "platform" to pass --platform.
# trivy rejects --platform for images that exist only in the local container
# runtime, so the caller falls back to a scan without it.
trivy_scan() {
  local idx="$1" target="$2" vexfile="$3" mode="$4"
  local args=(image --quiet --scanners vuln --format json --severity "${SEVERITY}"
    --output "${WORK_DIR}/scan-${idx}.json")
  [[ "${mode}" == "platform" ]] && args+=(--platform "linux/${ARCH}")
  [[ "${IGNORE_UNFIXED}" -eq 1 ]] && args+=(--ignore-unfixed)
  [[ -n "${vexfile}" ]] && args+=(--vex "${vexfile}")
  args+=("${SKIP_DB_ARGS[@]+"${SKIP_DB_ARGS[@]}"}" "${target}")
  trivy "${args[@]}" 2>"${WORK_DIR}/scan-${idx}.err"
}

scan_one() {
  local idx="$1" image="$2" target="$3" _hardened="$4" vexfile="$5"
  rm -f "${WORK_DIR}/scan-${idx}.json"
  if trivy_scan "${idx}" "${target}" "${vexfile}" platform; then
    return 0
  fi
  # Local-only images: retry without --platform.
  if trivy_scan "${idx}" "${target}" "${vexfile}" local; then
    return 0
  fi
  rm -f "${WORK_DIR}/scan-${idx}.json"
  return 0
}
export -f scan_one trivy_scan
export WORK_DIR SEVERITY ARCH IGNORE_UNFIXED
# Bash arrays cannot be exported; pass the DB flag through a string.
export SKIP_DB_FLAG="${SKIP_DB_ARGS[*]:-}"

log "Scanning ${IMAGE_COUNT} images with ${JOBS} parallel jobs..."
# shellcheck disable=SC2016
xargs -d '\n' -P "${JOBS}" -I{} bash -c '
  IFS=$'"'"'\t'"'"' read -r idx image target hardened vexfile <<<"$1"
  SKIP_DB_ARGS=(); [[ -n "${SKIP_DB_FLAG}" ]] && SKIP_DB_ARGS=(${SKIP_DB_FLAG})
  scan_one "$idx" "$image" "$target" "$hardened" "$vexfile"
' _ {} <"${WORK_DIR}/jobs.tsv"

# Parallel scans can fail on shared trivy cache locks or a busy container
# runtime. Retry each failed image once, one at a time.
while IFS=$'\t' read -r idx image target hardened vexfile; do
  [[ -s "${WORK_DIR}/scan-${idx}.json" ]] && continue
  log "Retrying ${image} sequentially..."
  scan_one "${idx}" "${image}" "${target}" "${hardened}" "${vexfile}"
  [[ -s "${WORK_DIR}/scan-${idx}.json" ]] || echo ">> scan failed: ${image} ($(tail -n 1 "${WORK_DIR}/scan-${idx}.err" 2>/dev/null))" >&2
done <"${WORK_DIR}/jobs.tsv"

# --- Step 3: report ----------------------------------------------------------
: >"${WORK_DIR}/rows.tsv"
while IFS=$'\t' read -r idx image _target hardened vexfile; do
  f="${WORK_DIR}/scan-${idx}.json"
  vex=no
  [[ -n "${vexfile}" ]] && vex=yes
  if [[ -s "${f}" ]]; then
    counts=$(jq -r '[.Results[]?.Vulnerabilities[]?.Severity] |
      "\(map(select(.=="CRITICAL"))|length)\t\(map(select(.=="HIGH"))|length)\t\(length)"' "${f}")
  else
    counts="error	error	error"
  fi
  printf '%s\t%s\t%s\t%s\n' "${image}" "${hardened}" "${vex}" "${counts}" >>"${WORK_DIR}/rows.tsv"
done <"${WORK_DIR}/jobs.tsv"

NON_HARDENED=$(awk -F'\t' '$2=="no"' "${WORK_DIR}/rows.tsv" | wc -l | tr -d ' ')
TOTAL_CRIT=$(awk -F'\t' '$4 ~ /^[0-9]+$/ {s+=$4} END {print s+0}' "${WORK_DIR}/rows.tsv")
TOTAL_HIGH=$(awk -F'\t' '$5 ~ /^[0-9]+$/ {s+=$5} END {print s+0}' "${WORK_DIR}/rows.tsv")
ERRORS=$(awk -F'\t' '$4=="error"' "${WORK_DIR}/rows.tsv" | wc -l | tr -d ' ')

case "${OUTPUT_FORMAT}" in
  json)
    jq -R -s --argjson nh "${NON_HARDENED}" --argjson c "${TOTAL_CRIT}" --argjson h "${TOTAL_HIGH}" --arg sev "${SEVERITY}" '
      [split("\n")[] | select(length>0) | split("\t") |
        {image: .[0], hardened: (.[1]=="yes"), vex_applied: (.[2]=="yes"),
         critical: (.[3]|tonumber? // null), high: (.[4]|tonumber? // null), total: (.[5]|tonumber? // null)}] as $rows |
      {severity: $sev, images: $rows,
       summary: {images: ($rows|length), non_hardened: $nh, critical: $c, high: $h}}' "${WORK_DIR}/rows.tsv"
    ;;
  csv)
    echo "image,hardened,vex_applied,critical,high,total"
    awk -F'\t' 'BEGIN{OFS=","} {print "\"" $1 "\"", $2, $3, $4, $5, $6}' "${WORK_DIR}/rows.tsv"
    ;;
  *)
    {
      printf 'IMAGE\tHARDENED\tVEX\tCRITICAL\tHIGH\tTOTAL\n'
      sort -t$'\t' -k2,2 -k1,1 "${WORK_DIR}/rows.tsv"
    } | column -t -s $'\t'
    echo
    echo "Severities in total: ${SEVERITY}. VEX = DHI VEX applied."
    ;;
esac

echo ">> Summary: ${IMAGE_COUNT} images, ${NON_HARDENED} not hardened, ${TOTAL_CRIT} critical, ${TOTAL_HIGH} high, ${ERRORS} scan errors." >&2

if [[ "${FAIL_ON_NON_HARDENED}" -eq 1 && "${NON_HARDENED}" -gt 0 ]]; then
  exit 2
fi
