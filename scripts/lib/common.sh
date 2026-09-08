#!/usr/bin/env bash

# Prevent sourcing multiple times.
if [[ -n "${GDCN_COMMON_SH_LOADED:-}" ]]; then
  return
fi
GDCN_COMMON_SH_LOADED=1

TF_OUTPUT_JSON=${TF_OUTPUT_JSON:-""}
TF_OUTPUTS_LOADED=${TF_OUTPUTS_LOADED:-0}

warn() {
  echo -e "Warning: $*" >&2
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

is_inside_container() {
  # Heuristics (ordered from most to least reliable):
  # 1. /.dockerenv exists in many Docker/Dev Container environments
  if [[ -f "/.dockerenv" ]]; then
    return 0
  fi

  # 2. cgroup v1: /proc/1/cgroup contains container runtime markers
  if [[ -r "/proc/1/cgroup" ]] && grep -qaE '(docker|containerd|kubepods)' "/proc/1/cgroup"; then
    return 0
  fi

  # 3. cgroup v2: /proc/1/mountinfo contains container overlay/cgroup markers
  if [[ -r "/proc/1/mountinfo" ]] && grep -qaE '(docker|containerd|kubepods)' "/proc/1/mountinfo"; then
    return 0
  fi

  # 4. container_env set by some container runtimes
  if [[ -n "${container:-}" ]]; then
    return 0
  fi

  return 1
}

# Sets DOCKER_CONNECT_TO_ARGS. A global rather than a nameref: `local -n` needs
# bash 4.3, and these scripts otherwise run on 4.0.
docker_internal_connect_to_args() {
  # If we're running inside a devcontainer, "localhost" refers to the container.
  # For local k3d (Docker-outside-of-Docker), the ingress port is on the Docker host.
  # Important: keep the URL hostname as-is so Ingress host routing works, but
  # connect to host.docker.internal underneath.
  local hostname="$1"
  DOCKER_CONNECT_TO_ARGS=()

  if is_inside_container && [[ "${hostname}" == "localhost" || "${hostname}" == *.localhost ]]; then
    if command_exists getent && getent hosts host.docker.internal >/dev/null 2>&1; then
      echo "Container detected, routing via host.docker.internal."
      DOCKER_CONNECT_TO_ARGS=(--connect-to "${hostname}:443:host.docker.internal:443")
    fi
  fi
}

require_command() {
  local binary="$1"
  local message="${2:-}"
  if command_exists "${binary}"; then
    return 0
  fi

  if [[ -n "${message}" ]]; then
    echo -e "Error: ${message}" >&2
  else
    echo -e "Error: Required command '${binary}' not found on PATH." >&2
  fi
  exit 1
}

load_tf_outputs() {
  if ! command_exists terraform; then
    warn "terraform CLI not found; run this script from the Terraform directory if you want automatic defaults."
    return
  fi

  if ! command_exists jq; then
    warn "jq CLI not found; install it to auto-populate values from Terraform outputs."
    return
  fi

  local tf_err
  tf_err=$(mktemp)
  if TF_OUTPUT_JSON=$(terraform output -json 2>"${tf_err}"); then
    TF_OUTPUTS_LOADED=1
  else
    warn "Failed to read Terraform outputs: $(tr '\n' ' ' <"${tf_err}")"
    warn "Ensure you've run 'terraform apply' in this directory."
  fi
  rm -f "${tf_err}"
}

has_tf_outputs() {
  [[ "${TF_OUTPUTS_LOADED}" -eq 1 ]] || return 1
  [[ -n "${TF_OUTPUT_JSON}" ]] || return 1

  if command_exists jq; then
    jq -e 'length > 0' <<<"${TF_OUTPUT_JSON}" >/dev/null 2>&1
  else
    [[ "${TF_OUTPUT_JSON}" != "{}" ]]
  fi
}

require_tf_outputs() {
  load_tf_outputs
  if ! has_tf_outputs; then
    echo ">> ERROR: Terraform outputs not available. Run 'terraform apply' first." >&2
    exit 1
  fi
}

require_tf_context() {
  local script_name="${1:-this script}"
  local dir_name has_context=1
  dir_name=$(basename "$(pwd)")

  case "${dir_name}" in
    aws | azure | local | stackit) ;;
    *) has_context=0 ;;
  esac

  if [[ ${has_context} -eq 1 ]] && ! has_tf_outputs; then
    has_context=0
  fi

  if [[ ${has_context} -eq 0 ]]; then
    cat <<EOF
Warning: Terraform context not detected.
From the repo root, change into your cloud provider directory and rerun for sane defaults:
  cd aws     && ../scripts/${script_name}
  # or
  cd azure   && ../scripts/${script_name}
  # or
  cd stackit && ../scripts/${script_name}
  # or
  cd local   && ../scripts/${script_name}
Proceeding without Terraform outputs; you'll need to enter values manually.
EOF
  fi
}

tf_output_value() {
  local key="$1"
  local fallback="${2:-}"
  local value=""

  if [[ "${TF_OUTPUTS_LOADED}" -eq 1 ]]; then
    value=$(jq -r --arg key "${key}" 'try .[$key].value // empty' <<<"${TF_OUTPUT_JSON}" 2>/dev/null || true)
    if [[ "${value}" == "null" ]]; then
      value=""
    fi
  fi

  if [[ -z "${value}" ]]; then
    value="${fallback}"
  fi

  printf '%s' "${value}"
}

join_by() {
  local delimiter="$1"
  shift || true
  local first=1
  for value in "$@"; do
    if [[ ${first} -eq 1 ]]; then
      printf '%s' "${value}"
      first=0
    else
      printf '%s%s' "${delimiter}" "${value}"
    fi
  done
}

trim() {
  local value="${1:-}"
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  printf '%s' "${value}"
}

die() {
  echo -e "\nError: $*" >&2
  exit 1
}

prompt_required() {
  local prompt="$1"
  local error="$2"
  local default="${3:-}"
  local value
  while true; do
    read -ep "${prompt}" value
    if [[ -z "${value}" && -n "${default}" ]]; then
      value="${default}"
    fi
    if [[ -n "${value}" ]]; then
      printf '%s\n' "${value}"
      return 0
    fi
    echo -e "\nError: ${error}\n" >&2
  done
}

prompt_password() {
  local prompt="$1"
  local error="$2"
  local value
  while true; do
    read -resp "${prompt}" value
    echo >&2
    if [[ -n "${value}" ]]; then
      printf '%s\n' "${value}"
      return 0
    fi
    echo -e "\nError: ${error}\n" >&2
  done
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-n}"
  local answer normalized
  while true; do
    read -ep "${prompt}" answer
    if [[ -z "${answer}" ]]; then
      answer="${default}"
    fi
    normalized=$(printf '%s' "${answer}" | tr '[:upper:]' '[:lower:]')
    case "${normalized}" in
      y|yes)
        printf 'yes\n'
        return 0
        ;;
      n|no)
        printf 'no\n'
        return 0
        ;;
      *)
        echo -e "\nError: Please answer yes or no.\n" >&2
        ;;
    esac
  done
}

prompt_choice() {
  local prompt="$1"
  local default="$2"
  shift 2
  local options=("$@")
  local value normalized option normalized_option

  while true; do
    read -ep "${prompt}" value
    value=$(trim "${value}")
    if [[ -z "${value}" ]]; then
      value="${default}"
    fi
    normalized=$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]')
    for option in "${options[@]}"; do
      normalized_option=$(printf '%s' "${option}" | tr '[:upper:]' '[:lower:]')
      if [[ "${normalized}" == "${normalized_option}" ]]; then
        printf '%s\n' "${option}"
        return 0
      fi
    done
    echo -e "\nError: Invalid option '${value}'. Allowed: $(join_by ", " "${options[@]}").\n" >&2
  done
}

urlencode() {
  jq -rn --arg v "${1}" '$v|@uri'
}

# Runs curl with the given args, prints "<body>\n<http_status>\n" on stdout,
# and returns success only if the status code is 2xx.
curl_with_status() {
  local response status body
  response=$(curl --silent --show-error --write-out "\n%{http_code}" "$@")
  status=${response##*$'\n'}
  body=${response%$'\n'*}

  printf '%s\n%s\n' "${body}" "${status}"

  [[ "${status}" =~ ^2 ]]
}

# Fetches a single field from a Kubernetes Secret's .data and base64-decodes it.
# Prints the decoded value on stdout; returns 1 if the field is missing/empty
# or cannot be decoded.
load_k8s_secret_field() {
  local namespace="$1" secret="$2" key="$3"
  local raw
  raw=$(kubectl get secret -n "${namespace}" "${secret}" -o jsonpath="{.data.${key}}" 2>/dev/null || true)
  [[ -n "${raw}" ]] || return 1
  printf '%s' "${raw}" | base64 -d 2>/dev/null
}
