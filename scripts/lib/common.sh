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
  # Heuristics:
  # - /.dockerenv exists in many Docker/Dev Container environments
  # - /proc/1/cgroup often contains container markers
  if [[ -f "/.dockerenv" ]]; then
    return 0
  fi

  if [[ -r "/proc/1/cgroup" ]] && grep -qaE '(docker|containerd|kubepods)' "/proc/1/cgroup"; then
    return 0
  fi

  return 1
}

rewrite_localhost_for_container() {
  # When running inside a container but talking to services exposed on the Docker
  # host (e.g., k3d publishes 443 on the host), "localhost" won't work.
  # In that case, prefer host.docker.internal when it resolves.
  local hostname="${1:-}"

  if is_inside_container; then
    if [[ "${hostname}" == "localhost" || "${hostname}" == *.localhost ]]; then
      if command_exists getent && getent hosts host.docker.internal >/dev/null 2>&1; then
        printf '%s' "${hostname/localhost/host.docker.internal}"
        return 0
      fi
    fi
  fi

  printf '%s' "${hostname}"
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

  if TF_OUTPUT_JSON=$(terraform output -json 2>/dev/null); then
    TF_OUTPUTS_LOADED=1
  else
    warn "Failed to read Terraform outputs. Ensure you've run 'terraform apply' in this directory."
  fi
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

require_tf_context() {
  local script_name="${1:-this script}"
  local dir_name has_context=1
  dir_name=$(basename "$(pwd)")

  if [[ "${dir_name}" != "aws" && "${dir_name}" != "azure" && "${dir_name}" != "local" ]]; then
    has_context=0
  elif ! has_tf_outputs; then
    has_context=0
  fi

  if [[ ${has_context} -eq 0 ]]; then
    cat <<EOF
Warning: Terraform context not detected.
From the repo root, change into your cloud provider directory and rerun for sane defaults:
  cd aws   && ../scripts/${script_name}
  # or
  cd azure && ../scripts/${script_name}
  # or
  cd local && ../scripts/${script_name}
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
