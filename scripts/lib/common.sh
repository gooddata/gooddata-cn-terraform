#!/usr/bin/env bash

# Prevent sourcing multiple times.
if [[ -n "${GDCN_COMMON_SH_LOADED:-}" ]]; then
  return
fi
GDCN_COMMON_SH_LOADED=1

TF_OUTPUT_JSON=${TF_OUTPUT_JSON:-""}
TF_OUTPUTS_LOADED=${TF_OUTPUTS_LOADED:-0}

warn() {
  echo -e ">> WARNING: $*" >&2
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_command() {
  local binary="$1"
  local message="${2:-}"
  if command_exists "${binary}"; then
    return 0
  fi

  if [[ -n "${message}" ]]; then
    echo -e ">> ERROR: ${message}" >&2
  else
    echo -e ">> ERROR: Required command '${binary}' not found on PATH." >&2
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

  if [[ "${dir_name}" != "aws" && "${dir_name}" != "azure" ]]; then
    has_context=0
  elif ! has_tf_outputs; then
    has_context=0
  fi

  if [[ ${has_context} -eq 0 ]]; then
    cat <<EOF
>> WARNING: Terraform context not detected.
>> From the repo root, change into your cloud provider directory and rerun for sane defaults:
>>   cd aws   && ../scripts/${script_name}
>>   # or
>>   cd azure && ../scripts/${script_name}
>> Proceeding without Terraform outputs; you'll need to enter values manually.
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



