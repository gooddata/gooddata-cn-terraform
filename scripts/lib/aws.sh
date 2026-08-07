#!/usr/bin/env bash

# AWS credential helpers for destroy-time cleanup. Deliberately free of the
# interactive helpers in common.sh: these run unattended from Terraform
# provisioners, where there is nobody to prompt.

if [[ -n "${GDCN_AWS_SH_LOADED:-}" ]]; then
  return
fi
GDCN_AWS_SH_LOADED=1

AWS_USE_PROFILE=""
AWS_BOUND_PROFILE=""

# Echoes the account id reachable with the given aws args, or nothing.
aws_account_of() {
  aws "$@" sts get-caller-identity --query Account --output text 2>/dev/null || true
}

# Pick credentials for a known account and refuse anything else.
#
# The profile recorded at apply time can be stale by destroy time (renamed or
# removed), so fall back to ambient credentials — but never act on credentials
# for a different account. Against the wrong account a lookup by name returns
# "not found", which reads as "already deleted", and a delete or terminate by
# name or tag would hit somebody else's resources.
aws_bind_account() {
  local profile="$1" expected="$2"

  # An empty expected account means the resource predates account pinning (the
  # trigger is under ignore_changes, so it is never backfilled). Keep the old
  # behaviour rather than blocking the destroy; the check arrives when the
  # resource is next replaced.
  if [[ -z "${expected}" ]]; then
    echo "WARNING: no account recorded; using the first working credentials without an account check."
    AWS_BOUND_PROFILE="${profile}"
    if [[ -n "${profile}" ]] && aws --profile "${profile}" sts get-caller-identity >/dev/null 2>&1; then
      AWS_USE_PROFILE=1
      return 0
    fi
    AWS_USE_PROFILE=""
    aws sts get-caller-identity >/dev/null 2>&1 && return 0
    echo "ERROR: no usable AWS credentials." >&2
    return 1
  fi

  AWS_BOUND_PROFILE="${profile}"
  if [[ -n "${profile}" ]] && [[ "$(aws_account_of --profile "${profile}")" == "${expected}" ]]; then
    AWS_USE_PROFILE=1
    return 0
  fi

  AWS_USE_PROFILE=""
  if [[ "$(aws_account_of)" == "${expected}" ]]; then
    echo "WARNING: profile '${profile}' unusable or bound to another account; using ambient credentials for ${expected}."
    return 0
  fi

  echo "ERROR: no credentials for account ${expected}; profile '${profile}' and the environment both fail or resolve elsewhere." >&2
  return 1
}

# Run the AWS CLI with whichever credentials aws_bind_account settled on.
# The profile stays a single argument whatever characters it contains.
awsx() {
  if [[ -n "${AWS_USE_PROFILE}" ]]; then
    aws --profile "${AWS_BOUND_PROFILE}" "$@"
  else
    aws "$@"
  fi
}

# Reject anything that is not a plain decimal count of seconds. Bash arithmetic
# would otherwise read 010 as octal 8, abort on 08, and silently take -1.
require_seconds() {
  local name="$1" value="$2"
  if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: ${name} must be a whole number of seconds, got '${value}'." >&2
    return 1
  fi
  # Length check first: bash arithmetic wraps past 2^63 and would turn a huge
  # value negative, which reads as a deadline in the past and skips the wait.
  if ((${#value} > 10)) || ((10#${value} > 2147483647)); then
    echo "ERROR: ${name} must be at most 2147483647 seconds, got '${value}'." >&2
    return 1
  fi
  printf '%d' "$((10#${value}))"
}
