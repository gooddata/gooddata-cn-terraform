###
# Provision Karpenter
#
# Karpenter provisions right-sized, on-demand EC2 capacity just-in-time in
# response to pending pods. The supporting IAM roles, instance profile, SQS
# interruption queue and EKS Pod Identity association are created by the
# upstream eks/karpenter submodule; the controller is installed via Helm and
# the provisioning policy is expressed as an EC2NodeClass + NodePool(s).
###

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.0"

  cluster_name = module.eks.cluster_name

  # v21 defaults to EKS Pod Identity (the pod-identity agent add-on is enabled
  # on the cluster) and v1 (>= 1.0) controller permissions; we just create the
  # association binding the kube-system/karpenter service account to the role.
  create_pod_identity_association = true

  # The generated controller policy exceeds the 6144-char managed-policy quota.
  # Inline role policies allow 10240, which fits.
  enable_inline_policy = true

  # Lets Karpenter-launched nodes use the EBS CSI driver and pull images
  # (incl. via the optional pull-through cache).
  node_iam_role_additional_policies = local.node_iam_role_additional_policies

  tags = local.common_tags
}

# Install the Karpenter controller into kube-system (runs on the fixed-size
# system node group defined in eks.tf).
resource "helm_release" "karpenter" {
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.helm_karpenter_version
  namespace  = "kube-system"

  wait    = true
  timeout = 1800

  values = [yamlencode({
    serviceAccount = {
      name = "karpenter"
    }
    # The chart's default 2 replicas require hostname anti-affinity to be
    # satisfiable, so one system node means one replica.
    replicas = min(local.system_node_count, 2)
    settings = {
      clusterName       = module.eks.cluster_name
      clusterEndpoint   = module.eks.cluster_endpoint
      interruptionQueue = module.karpenter.queue_name
    }
    controller = {
      resources = {
        requests = { cpu = "1", memory = "1Gi" }
        limits   = { memory = "1Gi" }
      }
    }
    # Run on the isolated system node group (CriticalAddonsOnly taint, eks.tf).
    tolerations = [{ key = "CriticalAddonsOnly", operator = "Exists" }]
  })]

  depends_on = [module.eks, module.karpenter]
}

# EC2NodeClass: how Karpenter builds nodes (Bottlerocket AMI, node IAM role,
# subnet/SG discovery by the karpenter.sh/discovery tag set in vpc.tf/eks.tf).
resource "kubectl_manifest" "karpenter_node_class" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "default"
    }
    spec = {
      amiFamily        = "Bottlerocket"
      role             = module.karpenter.node_iam_role_name
      amiSelectorTerms = [{ alias = "bottlerocket@latest" }]
      subnetSelectorTerms = [{
        tags = { "karpenter.sh/discovery" = var.deployment_name }
      }]
      securityGroupSelectorTerms = [{
        tags = { "karpenter.sh/discovery" = var.deployment_name }
      }]
      tags = merge(local.common_tags, {
        "karpenter.sh/discovery" = var.deployment_name
      })
      # Bottlerocket's default 20 GiB /dev/xvdb is below the ephemeral-storage
      # some pods request, leaving them unschedulable on every instance type.
      blockDeviceMappings = [{
        deviceName = "/dev/xvdb"
        ebs = {
          volumeSize          = "${var.eks_node_disk_size}Gi"
          volumeType          = "gp3"
          encrypted           = true
          deleteOnTermination = true
        }
      }]
      # Karpenter sizes maxPods from secondary-IP limits, leaving prefix
      # delegation (eks.tf) inert. 110 fits every node these pools build.
      kubelet = {
        maxPods = var.eks_node_max_pods
      }
    }
  })

  depends_on = [helm_release.karpenter]
}

# General-purpose NodePool: on-demand AMD m category (modern gens) with a
# per-node vCPU cap (size-profiles.tf). Category "m" is inherently 4 GiB/vCPU
# general-purpose (no low-memory variants); instance-cpu-manufacturer pins AMD
# (m*a) to drop Intel (m*i), matching the AMD-only, 4 GiB/vCPU fleet on Azure.
# A broad category (not an explicit type list) within AMD still maximizes
# capacity resilience; instance-cpu + the CPU limit bound size and cost.
resource "kubectl_manifest" "karpenter_node_pool" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "general"
    }
    spec = {
      template = {
        spec = {
          requirements = [
            { key = "kubernetes.io/arch", operator = "In", values = ["amd64"] },
            { key = "kubernetes.io/os", operator = "In", values = ["linux"] },
            { key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] },
            { key = "karpenter.k8s.aws/instance-category", operator = "In", values = ["m"] },
            { key = "karpenter.k8s.aws/instance-cpu-manufacturer", operator = "In", values = ["amd"] },
            { key = "karpenter.k8s.aws/instance-generation", operator = "Gt", values = ["5"] },
            { key = "karpenter.k8s.aws/instance-cpu", operator = "Lt", values = [tostring(local.eks_node_cpu_max + 1)] },
          ]
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default"
          }
          expireAfter = "720h"
        }
      }
      # Total vCPU ceiling for this NodePool (size-profiles.tf). StarRocks pool
      # below is uncapped (bounded by fixed replicas).
      limits = {
        cpu = local.eks_node_cpu_limit
      }
      # 15m of underutilization before reclaiming a node, so bursty workloads
      # do not churn capacity.
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "15m"
      }
    }
  })

  depends_on = [kubectl_manifest.karpenter_node_class]
}

# StarRocks NodePool: dedicated taint+label so FE/CN pods are isolated, on the
# StarRocks instance types from the size profile. Zonal placement (EBS is
# zonal) is handled automatically by Karpenter via volume topology, so no
# per-AZ pools are needed.
resource "kubectl_manifest" "karpenter_node_pool_starrocks" {
  count = var.enable_ai_lake ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "starrocks"
    }
    spec = {
      template = {
        metadata = {
          labels = { workload = "starrocks" }
        }
        spec = {
          taints = [{
            key    = "workload"
            value  = "starrocks"
            effect = "NoSchedule"
          }]
          requirements = [
            { key = "kubernetes.io/arch", operator = "In", values = ["amd64"] },
            { key = "kubernetes.io/os", operator = "In", values = ["linux"] },
            { key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] },
            { key = "node.kubernetes.io/instance-type", operator = "In", values = local.eks_ai_lake_node_types },
          ]
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default"
          }
          expireAfter = "720h"
        }
      }
      # WhenEmpty (not WhenEmptyOrUnderutilized like the general pool): StarRocks
      # FE/CN are stateful with zonal EBS volumes, so only reclaim truly empty
      # nodes rather than consolidating/evicting running stateful pods.
      disruption = {
        consolidationPolicy = "WhenEmpty"
        consolidateAfter    = "1m"
      }
    }
  })

  depends_on = [kubectl_manifest.karpenter_node_class]
}

# ---------------------------------------------------------------------------
# Karpenter destroy-time NodeClaim drain
# ---------------------------------------------------------------------------
# Only Karpenter can reap its own nodes, by clearing each NodeClaim finalizer.
# Removing the controller first orphans them: the instances keep billing and
# their ENIs block subnet, security group and VPC deletion.
#
# Destroy order, enforced by depends_on here and in k8s-common.tf:
#   helm releases  →  nodeclaim_drain  →  node pools  →  node class  →  karpenter
# ---------------------------------------------------------------------------
resource "null_resource" "karpenter_nodeclaim_drain" {
  triggers = {
    cluster_name = module.eks.cluster_name
    aws_region   = var.aws_region
    aws_profile  = var.aws_profile_name
  }

  lifecycle {
    # Any trigger change replaces this resource, which runs the drain below. The
    # profile is a local credential detail, so renaming it must not delete nodes.
    ignore_changes = [triggers["aws_profile"]]
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      set -eu

      command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not found"; exit 1; }
      command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found"; exit 1; }

      cluster_name="${self.triggers.cluster_name}"
      aws_region="${self.triggers.aws_region}"
      aws_profile="${self.triggers.aws_profile}"

      # The recorded profile is deliberately not replacement-sensitive, so it can
      # be stale by destroy time (renamed or removed). Prefer it, fall back to
      # whatever credentials the environment provides, rather than leaving nodes
      # running whose ENIs block VPC deletion.
      if aws sts get-caller-identity --profile "$aws_profile" >/dev/null 2>&1; then
        aws_creds="--profile $aws_profile"
      elif aws sts get-caller-identity >/dev/null 2>&1; then
        echo "WARNING: profile '$aws_profile' is unusable; using ambient AWS credentials."
        aws_creds=""
      else
        echo "ERROR: no usable AWS credentials (profile '$aws_profile' and environment both failed)." >&2
        exit 1
      fi

      # Terminate any instance Karpenter still owns. Only needs the EC2 API, so
      # it is also the fallback when the cluster itself is unreachable.
      force_terminate_instances() {
        ids=$(aws ec2 describe-instances --region "$aws_region" $aws_creds \
          --filters "Name=tag:kubernetes.io/cluster/$cluster_name,Values=owned" \
                    "Name=tag-key,Values=karpenter.sh/nodeclaim" \
                    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
          --query 'Reservations[].Instances[].InstanceId' --output text) || {
          echo "ERROR: cannot list Karpenter instances to force-terminate." >&2
          exit 1
        }

        if [ -z "$ids" ]; then
          echo "No Karpenter-owned instances remain."
          return 0
        fi

        echo "Terminating $ids"
        aws ec2 terminate-instances --region "$aws_region" $aws_creds \
          --instance-ids $ids >/dev/null || {
          echo "ERROR: terminate-instances failed." >&2
          exit 1
        }
        # ENIs only detach once instances reach terminated, and they block
        # subnet, security group and VPC deletion until they do.
        echo "Waiting for termination so their ENIs are released..."
        aws ec2 wait instance-terminated --region "$aws_region" $aws_creds \
          --instance-ids $ids || echo "WARNING: waiter timed out; VPC deletion may retry."
      }

      kubeconfig=$(mktemp)
      trap 'rm -f "$kubeconfig"' EXIT

      # Distinguish an already-deleted cluster from a real API error (expired
      # credentials, wrong profile, no network), which must not skip the drain.
      if ! err=$(aws eks update-kubeconfig --name "$cluster_name" --region "$aws_region" \
        $aws_creds --kubeconfig "$kubeconfig" 2>&1); then
        if echo "$err" | grep -q "ResourceNotFoundException"; then
          echo "Cluster '$cluster_name' no longer exists; checking for orphaned instances."
          force_terminate_instances
          exit 0
        fi
        echo "ERROR: cannot reach cluster '$cluster_name' in '$aws_region': $err" >&2
        exit 1
      fi

      kc="kubectl --kubeconfig $kubeconfig"

      # Unreachable API means Karpenter cannot reap its own nodes, so do it via
      # EC2 instead. Exiting here would strand instances whose ENIs then block
      # subnet, security group and VPC deletion.
      if ! $kc get --raw /readyz >/dev/null 2>&1; then
        echo "WARNING: cluster '$cluster_name' is unreachable; terminating its instances directly."
        force_terminate_instances
        exit 0
      fi

      if ! $kc get crd nodeclaims.karpenter.sh >/dev/null 2>&1; then
        echo "NodeClaim CRD not installed; checking for orphaned instances."
        force_terminate_instances
        exit 0
      fi

      # Fails instead of printing 0 when the API call itself fails, so a
      # transient error is never mistaken for an empty cluster.
      count_claims() {
        out=$($kc get nodeclaims --no-headers 2>/dev/null) || return 1
        if [ -z "$out" ]; then echo 0; else echo "$out" | wc -l | tr -d ' '; fi
      }

      if ! remaining=$(count_claims); then
        echo "ERROR: cannot list NodeClaims on '$cluster_name'." >&2
        exit 1
      fi
      if [ "$remaining" = "0" ]; then
        echo "No NodeClaims to drain."
        exit 0
      fi

      echo "Deleting $remaining Karpenter NodeClaim(s)..."
      $kc delete nodeclaims --all --wait=false >/dev/null 2>&1 || true

      # The finalizer clears only after the instance is terminated, so a claim
      # disappearing means its node is really gone.
      echo "Waiting up to 900s for Karpenter to terminate them..."
      i=0
      while [ "$i" -lt 90 ]; do
        if remaining=$(count_claims); then
          if [ "$remaining" = "0" ]; then
            echo "All NodeClaims drained."
            exit 0
          fi
          echo "Still waiting for $remaining NodeClaim(s)..."
        else
          echo "WARNING: could not list NodeClaims, retrying..."
        fi
        sleep 10
        i=$((i + 1))
      done

      # Karpenter is wedged. Failing here would leave the stack undestroyable,
      # so do its job directly: terminate the instances, then clear finalizers.
      echo "WARNING: NodeClaim(s) still present after 900s; forcing cleanup."

      # Terminate before clearing finalizers, so no instance is left orphaned.
      force_terminate_instances

      # Karpenter clears the finalizer only after it observes the instance gone,
      # which it cannot do once it has lost EC2 API reachability.
      for nc in $($kc get nodeclaims -o name 2>/dev/null); do
        $kc patch "$nc" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
      done

      echo "Forced cleanup complete."
    EOT
  }

  # Node egress must outlive the drain: kubelets reach the public EKS endpoint
  # and Karpenter the EC2 API over module.vpc's NAT gateway.
  depends_on = [
    kubectl_manifest.karpenter_node_pool,
    kubectl_manifest.karpenter_node_pool_starrocks,
    module.vpc,
    aws_vpc_endpoint.s3,
  ]
}
