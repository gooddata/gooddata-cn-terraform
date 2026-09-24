# Family B: pods not healthy

Pods stay Pending, restart, get killed, or never pull their image. Workloads in
the `gooddata-cn` namespace are named `gooddata-cn-<component>`, for example
`gooddata-cn-metadata-api`, `gooddata-cn-calcique`, `gooddata-cn-sql-executor`,
`gooddata-cn-result-cache`, `gooddata-cn-export-builder`, `gooddata-cn-dex`,
plus the StatefulSets `gooddata-cn-etcd` and `gooddata-cn-redis-ha-server`.
Pulsar runs in `pulsar`; the metadata database is RDS (AWS), Azure Database for
PostgreSQL (Azure), or an in-cluster CloudNativePG cluster (local).

## Check these first

1. **Which pods, in which state.**
   ```bash
   kubectl get pods -n gooddata-cn -o wide | grep -v -E 'Running|Completed'
   kubectl get pods -n pulsar -o wide | grep -v -E 'Running|Completed'
   ```
2. **Why, from the pod's own events.**
   ```bash
   kubectl describe pod <pod> -n <ns> | sed -n '/^Events/,$p'
   kubectl get events -n <ns> --sort-by=.lastTimestamp | tail -30
   ```
   The event text is the diagnosis in most cases: `Insufficient cpu`,
   `Insufficient memory`, `no nodes available`, `pod has unbound immediate
   PersistentVolumeClaims`, `toomanyrequests` (Docker Hub rate limit),
   `secret "..." not found`, `Back-off restarting failed container`.
3. **Node capacity and health.**
   ```bash
   kubectl get nodes
   kubectl top nodes
   kubectl describe node <node> | sed -n '/Allocated resources/,/Events/p'
   ```
4. **Storage.**
   ```bash
   kubectl get pvc -A | grep -v Bound
   kubectl get storageclass
   ```
5. **Crash reason and previous logs** (CrashLoopBackOff, OOMKilled).
   ```bash
   kubectl describe pod <pod> -n gooddata-cn | grep -A6 'Last State'
   kubectl logs <pod> -n gooddata-cn --previous --tail=200
   ```
   `Reason: OOMKilled` is a memory limit, not a crash. Anything else: read the
   last lines and route by content (license or token errors go to family D,
   database or Pulsar connection errors go to family E).
6. **Node autoscaling, cloud only.**
   - AWS: Karpenter provisions nodes on demand.
     ```bash
     kubectl get nodeclaims,nodepools
     kubectl get pods -A | grep karpenter
     ```
     A NodeClaim that never becomes Ready, or no NodeClaim at all while pods are
     Pending, points at the CPU ceiling from `size_profile` (override with
     `eks_node_cpu_limit`) or at an AWS quota, visible in the Karpenter logs.
   - Azure: AKS node auto provisioning handles it; `kubectl get nodes` grows
     within minutes. If not, `az aks show` and the activity log in the portal
     show quota errors.
   - local: nothing scales. The three k3d nodes share the Docker host's CPU and
     memory.

## You can fix this yourself

Every command here is gated: list it, wait for a yes.

- **Pending for capacity on local.** Give Docker more CPU and memory (Docker
  Desktop settings, then `k3d cluster stop` and `start`), or reduce the
  footprint in `settings.tfvars`: `enable_ai_features = false` removes the
  gen-ai pods and Qdrant, and leaving `enable_observability` off saves the
  monitoring stack. Apply through the saved-plan flow.
- **Pending for capacity on a cloud.** Wait for the autoscaler first (five
  minutes is normal on a fresh cluster). If a limit blocks it, raise the CPU
  ceiling in `settings.tfvars` and apply.
- **Unbound PVC.** Check that the storage class in the claim exists (`gp3` on
  AWS, `managed-csi` or `premium-ssd-v2` on Azure, `local-path` on k3d). A claim
  for a class that does not exist comes from a tfvars override; fix the value
  and apply.
- **ImagePullBackOff with `toomanyrequests`.** Docker Hub is rate limiting
  anonymous pulls. On AWS and Azure set `enable_image_cache = true` with
  `dockerhub_username` and `dockerhub_access_token`; on local set the two Docker
  Hub variables so k3d's registry mirror authenticates. Apply, then delete the
  stuck pods so they re-pull: `kubectl delete pod <pod> -n gooddata-cn`.
- **OOMKilled repeatedly.** Limits come from the size profile
  (`modules/k8s-common/templates/gdcn-size-<profile>.yaml.tftpl`). Copy that
  component's block into `gdcn_helm_extra_values` in `settings.tfvars` with a
  higher `resources.limits.memory`, plan, and apply. Never `kubectl edit` the
  Deployment; the next apply reverts it. A single OOM right after install,
  while caches warm up, is not worth an override.
- **One pod wedged while its siblings are fine.**
  `kubectl delete pod <pod> -n gooddata-cn` and watch the replacement. Do this
  once; if the replacement fails the same way, the cause is elsewhere.
- **Never delete a PersistentVolumeClaim** of `gooddata-cn-etcd`,
  `gooddata-cn-redis-ha-server`, Pulsar, SeaweedFS, or the local PostgreSQL
  cluster. That is data loss, not a fix.

## Needs a GoodData support ticket

- OOMKilled on a `prod-small` or larger profile with default limits and no
  unusual load.
- CrashLoopBackOff with a stack trace from a GoodData.CN component that names no
  external dependency (database, Pulsar, Redis, license).
- An etcd or Redis StatefulSet pod that will not become Ready with healthy
  storage and nodes.

Do not delete the pod again or raise limits further at this point.

## What to include

`kubectl get pods -n gooddata-cn -o wide`, the `describe` events of the failing
pod, its `--previous` logs with secrets removed, `kubectl top nodes`, the
`size_profile`, and any `gdcn_helm_extra_values` override in use (values only,
no secrets).

## Deeper investigation (observability on)

Dashboard `GoodData-CN / Overall Health`, section 1 (Pods Ready, OOM Kills) and
section 3 (memory percent of limits, CPU throttling). In Prometheus:

```
sum by (container) (kube_pod_container_status_last_terminated_reason{namespace="gooddata-cn",reason="OOMKilled"})
container_memory_working_set_bytes{namespace="gooddata-cn"} / on (pod,container) kube_pod_container_resource_limits{resource="memory"}
```

Memory close to 100 percent of the limit for one component predicts the next
OOM kill and names the override to make.

## See also

- Family C when the pods failed during an apply that also failed.
- Family E when pods are Running but the product misbehaves.
