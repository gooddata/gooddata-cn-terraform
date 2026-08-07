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

  if [[ -z "${expected}" ]]; then
    echo "ERROR: no expected AWS account id supplied; refusing to run." >&2
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
