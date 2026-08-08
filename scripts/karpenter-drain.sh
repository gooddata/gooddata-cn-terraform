#!/usr/bin/env bash
#
# Reap Karpenter-owned nodes before Terraform removes the controller.
#
# Only Karpenter can clear a NodeClaim's finalizer. Remove the controller while
# claims exist and the instances keep billing while their ENIs block subnet,
# security group and VPC deletion. Terraform runs this from the destroy-time
# provisioner on null_resource.karpenter_nodeclaim_drain (aws/karpenter.tf);
# it is also safe to run by hand to finish a teardown that died halfway.
#
# Env: CLUSTER_NAME, AWS_REGION, AWS_PROFILE_NAME, AWS_ACCOUNT_ID
#      DRAIN_TIMEOUT_SECONDS (default 900)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/aws.sh
source "${SCRIPT_DIR}/lib/aws.sh"

CLUSTER_NAME="${CLUSTER_NAME:?CLUSTER_NAME is required}"
AWS_REGION="${AWS_REGION:?AWS_REGION is required}"
AWS_PROFILE_NAME="${AWS_PROFILE_NAME:-}"
# May be empty for resources created before account pinning; see lib/aws.sh.
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID-}"
DRAIN_TIMEOUT_SECONDS="${DRAIN_TIMEOUT_SECONDS:-900}"
DRAIN_TIMEOUT_SECONDS=$(require_seconds DRAIN_TIMEOUT_SECONDS "${DRAIN_TIMEOUT_SECONDS}") || exit 1

command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not found" >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found" >&2; exit 1; }

aws_bind_account "${AWS_PROFILE_NAME}" "${AWS_ACCOUNT_ID}" || exit 1

# Terminate whatever Karpenter still owns. Needs only the EC2 API, so it is
# also the fallback whenever the cluster itself is unreachable.
force_terminate_instances() {
  local ids
  ids=$(awsx ec2 describe-instances --region "${AWS_REGION}" \
    --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
    "Name=tag-key,Values=karpenter.sh/nodeclaim" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text) || {
    echo "ERROR: cannot list Karpenter instances to force-terminate." >&2
    exit 1
  }

  if [[ -z "${ids}" ]]; then
    echo "No Karpenter-owned instances remain."
    return 0
  fi

  echo "Terminating ${ids}"
  # shellcheck disable=SC2086 # ids is a space-separated list of instance ids
  awsx ec2 terminate-instances --region "${AWS_REGION}" --instance-ids ${ids} >/dev/null || {
    echo "ERROR: terminate-instances failed." >&2
    exit 1
  }
  # ENIs detach only once instances reach terminated, and they block subnet,
  # security group and VPC deletion until they do.
  echo "Waiting for termination so their ENIs are released..."
  # shellcheck disable=SC2086
  awsx ec2 wait instance-terminated --region "${AWS_REGION}" --instance-ids ${ids} ||
    echo "WARNING: waiter timed out; VPC deletion may retry."
}

kubeconfig=$(mktemp)
trap 'rm -f "${kubeconfig}"' EXIT

# Distinguish an already-deleted cluster from a real API error (expired
# credentials, no network), which must not be mistaken for nothing to do.
if ! err=$(awsx eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
  --kubeconfig "${kubeconfig}" 2>&1); then
  if grep -q "ResourceNotFoundException" <<<"${err}"; then
    echo "Cluster '${CLUSTER_NAME}' no longer exists; checking for orphaned instances."
    force_terminate_instances
    exit 0
  fi
  echo "ERROR: cannot reach cluster '${CLUSTER_NAME}' in '${AWS_REGION}': ${err}" >&2
  exit 1
fi

# --request-timeout: kubectl defaults to 0 (wait forever), so a blackholed API
# server would hang the destroy instead of falling through to the EC2 sweep.
kc() { kubectl --kubeconfig "${kubeconfig}" --request-timeout=15s "$@"; }

if ! kc get --raw /readyz >/dev/null 2>&1; then
  echo "WARNING: cluster '${CLUSTER_NAME}' is unreachable; terminating its instances directly."
  force_terminate_instances
  exit 0
fi

# Only a genuine NotFound means Karpenter was never installed. /readyz is served
# to any authenticated identity, so a principal without an EKS access entry gets
# this far and then 403s here — terminating every node without draining first.
if ! crd_err=$(kc get crd nodeclaims.karpenter.sh 2>&1 >/dev/null); then
  if grep -qi "not found" <<<"${crd_err}"; then
    echo "NodeClaim CRD not installed; checking for orphaned instances."
    force_terminate_instances
    exit 0
  fi
  echo "ERROR: cannot read the NodeClaim CRD on '${CLUSTER_NAME}': ${crd_err}" >&2
  exit 1
fi

# Delete the NodePools first. NodeClaims carry an ownerReference to their
# NodePool, so this cascades to every claim and, unlike deleting claims
# directly, leaves Karpenter with no pool from which to launch replacements.
if kc get crd nodepools.karpenter.sh >/dev/null 2>&1; then
  echo "Deleting Karpenter NodePools so their NodeClaims cascade..."
  kc delete nodepools --all --wait=false >/dev/null 2>&1 || true
fi

# Fail instead of printing 0 when the API call itself fails, so a transient
# error is never mistaken for an empty cluster.
count_claims() {
  local out
  out=$(kc get nodeclaims --no-headers 2>/dev/null) || return 1
  if [[ -z "${out}" ]]; then echo 0; else wc -l <<<"${out}" | tr -d ' '; fi
}

if ! remaining=$(count_claims); then
  echo "ERROR: cannot list NodeClaims on '${CLUSTER_NAME}'." >&2
  exit 1
fi
if [[ "${remaining}" == "0" ]]; then
  echo "No NodeClaims to drain."
  exit 0
fi

echo "Waiting up to ${DRAIN_TIMEOUT_SECONDS}s for Karpenter to terminate ${remaining} NodeClaim(s)..."
deadline=$((SECONDS + DRAIN_TIMEOUT_SECONDS))
while ((SECONDS < deadline)); do
  if remaining=$(count_claims); then
    if [[ "${remaining}" == "0" ]]; then
      echo "All NodeClaims drained."
      exit 0
    fi
    echo "Still waiting for ${remaining} NodeClaim(s)..."
  else
    echo "WARNING: could not list NodeClaims, retrying..."
  fi
  sleep 10
done

# Karpenter is wedged. Failing here would leave the stack undestroyable, so do
# its job directly: terminate the instances, then clear the finalizers.
echo "WARNING: NodeClaim(s) still present after ${DRAIN_TIMEOUT_SECONDS}s; forcing cleanup."
force_terminate_instances

# Karpenter clears a finalizer only once it observes the instance gone, which
# it cannot do after losing EC2 API reachability.
for nc in $(kc get nodeclaims -o name 2>/dev/null); do
  kc patch "${nc}" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
done

echo "Forced cleanup complete."
