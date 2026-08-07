#!/usr/bin/env bash
#
# Wait for (or force) deletion of the ALB before Terraform tears down the VPC.
#
# The ALB is created out of band by the AWS Load Balancer Controller inside
# EKS. Deleting the Ingress starts an async cleanup; if Terraform races ahead
# and removes subnets, the IGW or the ACM cert first, the destroy hangs.
# Terraform runs this from the destroy-time provisioner on
# null_resource.alb_cleanup_wait (aws/alb-ingress.tf); it is also safe to run
# by hand to finish a teardown that died halfway.
#
# Env: LB_NAME, AWS_REGION, AWS_PROFILE_NAME, AWS_ACCOUNT_ID
#      ALB_DELETE_TIMEOUT_SECONDS (default 300), ENI_TIMEOUT_SECONDS (default 120)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/aws.sh
source "${SCRIPT_DIR}/lib/aws.sh"

LB_NAME="${LB_NAME:?LB_NAME is required}"
AWS_REGION="${AWS_REGION:?AWS_REGION is required}"
AWS_PROFILE_NAME="${AWS_PROFILE_NAME:-}"
# May be empty for resources created before account pinning; see lib/aws.sh.
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID-}"
ALB_DELETE_TIMEOUT_SECONDS="${ALB_DELETE_TIMEOUT_SECONDS:-300}"
ALB_DELETE_TIMEOUT_SECONDS=$(require_seconds ALB_DELETE_TIMEOUT_SECONDS "${ALB_DELETE_TIMEOUT_SECONDS}") || exit 1
ENI_TIMEOUT_SECONDS="${ENI_TIMEOUT_SECONDS:-120}"
ENI_TIMEOUT_SECONDS=$(require_seconds ENI_TIMEOUT_SECONDS "${ENI_TIMEOUT_SECONDS}") || exit 1

command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not found" >&2; exit 1; }

aws_bind_account "${AWS_PROFILE_NAME}" "${AWS_ACCOUNT_ID}" || exit 1

# ENIs must detach before the VPC's subnets and security groups can go. The ALB
# object disappearing does not mean they have: this runs on every path, not just
# the force-delete one, or the common case races VPC deletion.
wait_for_enis() {
  local deadline=$((SECONDS + ENI_TIMEOUT_SECONDS)) eni_output
  echo "Waiting for ALB ENIs to be released..."
  while ((SECONDS < deadline)); do
    eni_output=$(awsx ec2 describe-network-interfaces \
      --filters "Name=description,Values=*ELB app/${LB_NAME}/*" \
      --region "${AWS_REGION}" \
      --query 'length(NetworkInterfaces)' \
      --output text 2>&1) || {
      echo "WARNING: failed to query ENIs in '${AWS_REGION}': ${eni_output} (will retry)"
      sleep 5
      continue
    }
    if [[ "${eni_output}" == "0" ]]; then
      echo "ALB ENIs released."
      return 0
    fi
    echo "Still waiting for ${eni_output} ENI(s)..."
    sleep 5
  done
  # Not fatal: Terraform retries subnet and security-group deletion, and failing
  # here would turn a slow detach into a failed destroy.
  echo "WARNING: ALB ENIs still attached after ${ENI_TIMEOUT_SECONDS}s; VPC deletion may retry."
}

# Distinguish "ALB not found" from real API errors (auth, throttling, etc.).
alb_exists() {
  local output rc=0
  output=$(awsx elbv2 describe-load-balancers --names "${LB_NAME}" --region "${AWS_REGION}" 2>&1) || rc=$?
  if ((rc == 0)); then
    return 0
  elif grep -q "LoadBalancerNotFound" <<<"${output}"; then
    return 1
  fi
  echo "ERROR: unexpected AWS API error in '${AWS_REGION}': ${output}" >&2
  exit 1
}

if ! alb_exists; then
  echo "ALB '${LB_NAME}' does not exist; checking its ENIs are gone."
  wait_for_enis
  exit 0
fi

echo "Waiting up to ${ALB_DELETE_TIMEOUT_SECONDS}s for the AWS Load Balancer Controller to delete '${LB_NAME}'..."
deadline=$((SECONDS + ALB_DELETE_TIMEOUT_SECONDS))
while ((SECONDS < deadline)); do
  if ! alb_exists; then
    echo "ALB '${LB_NAME}' deleted by the controller."
    wait_for_enis
    exit 0
  fi
  sleep 10
done

echo "WARNING: ALB '${LB_NAME}' still exists; force-deleting."
lb_arn=$(awsx elbv2 describe-load-balancers \
  --names "${LB_NAME}" \
  --region "${AWS_REGION}" \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text 2>&1) || {
  echo "ERROR: failed to fetch the ARN for '${LB_NAME}' in '${AWS_REGION}': ${lb_arn}" >&2
  exit 1
}

if [[ -z "${lb_arn}" || "${lb_arn}" == "None" ]]; then
  echo "ALB '${LB_NAME}' was deleted between the check and the ARN fetch."
  wait_for_enis
  exit 0
fi

delete_output=$(awsx elbv2 delete-load-balancer \
  --load-balancer-arn "${lb_arn}" \
  --region "${AWS_REGION}" 2>&1) || {
  if grep -q "LoadBalancerNotFound" <<<"${delete_output}"; then
    echo "ALB was already deleted (race). Continuing."
  else
    echo "ERROR: failed to delete '${LB_NAME}' in '${AWS_REGION}': ${delete_output}" >&2
    exit 1
  fi
}

wait_for_enis
