# Family F: teardown stuck

`terraform destroy` hangs or fails, a namespace stays Terminating, or cloud
resources survive the destroy. Terraform removes what it created; resources
created by controllers inside the cluster (the AWS load balancer, Karpenter
nodes, dynamically provisioned volumes) need the cluster alive to clean up, and
that is where teardowns die.

## Check these first

1. **What the destroy is waiting on.** The last resource named in the Terraform
   output is the blocker. Common ones: `kubectl_manifest.gdcn_organization`
   (finalizer), `aws_subnet` or `aws_vpc` (dependencies still attached),
   `aws_db_instance` (deletion protection), a Kubernetes namespace.
2. **Credentials.** A destroy that dies with `ExpiredToken` or `failed to
   refresh cached credentials` just needs `aws sso login --profile
   <aws_profile_name>` and the same command again (family C).
3. **Cluster still reachable.**
   ```bash
   kubectl get nodes
   kubectl get ns | grep Terminating
   kubectl get organization -n gooddata-cn
   ```
4. **AWS leftovers by name.**
   ```bash
   aws elbv2 describe-load-balancers --profile <aws_profile_name> --region <aws_region> --query 'LoadBalancers[].[LoadBalancerName,State.Code]'
   aws ec2 describe-instances --profile <aws_profile_name> --region <aws_region> --filters "Name=tag:kubernetes.io/cluster/<deployment_name>,Values=owned" --query 'Reservations[].Instances[].[InstanceId,State.Name]'
   aws ec2 describe-volumes --profile <aws_profile_name> --region <aws_region> --filters Name=status,Values=available --query 'Volumes[].[VolumeId,Size,Tags]'
   ```
5. **Azure leftovers.**
   ```bash
   az group show --name <resource group>
   az resource list --resource-group <resource group> -o table
   ```

## You can fix this yourself

Everything here deletes cloud resources: state the command, wait for a yes.

- **RDS deletion protection (AWS, prod profiles).** Set
  `rds_deletion_protection = false` in `settings.tfvars`, plan and apply, then
  destroy again. This is by design; the example file says so.
- **Karpenter nodes block subnet or VPC deletion (AWS).** Only Karpenter can
  clear a NodeClaim's finalizer, so nodes must go before the controller does.
  Terraform runs `scripts/karpenter-drain.sh` during destroy; when a destroy
  died halfway, run it by hand from the repo root:
  ```bash
  CLUSTER_NAME=<deployment_name> AWS_REGION=<aws_region> AWS_PROFILE_NAME=<aws_profile_name> scripts/karpenter-drain.sh
  ```
  It falls back to terminating the instances by tag when the cluster is already
  unreachable.
- **The ALB blocks subnet, IGW, or certificate deletion (AWS).** The load
  balancer controller deletes the ALB asynchronously. Run the cleanup by hand
  with the load balancer name from step 4:
  ```bash
  LB_NAME=<name> AWS_REGION=<aws_region> AWS_PROFILE_NAME=<aws_profile_name> scripts/alb-cleanup.sh
  ```
  Then destroy again.
- **Organization stuck Terminating.** A healthy organization controller clears
  the finalizer on its own. When the release is already gone, remove it by
  hand with the command in family D (the strongest gate in this skill), then
  destroy again.
- **Namespace stuck Terminating after the Organizations are gone.** List what
  is left inside it:
  ```bash
  kubectl api-resources --verbs=list --namespaced -o name | xargs -n1 kubectl get -n <ns> --ignore-not-found --show-kind
  ```
  Objects with finalizers from a controller that no longer runs are the
  blockers. Remove the finalizer from each listed object, one at a time, after
  confirmation. Removing finalizers from the namespace object itself is the last
  resort, because it orphans whatever those finalizers guarded.
- **Orphaned EBS volumes after a finished destroy (AWS).** Volumes created by
  the EBS CSI driver for PersistentVolumeClaims carry cluster tags but not
  Terraform's, so destroy skips them and they keep billing. From step 4, delete
  the `available` volumes whose tags name this cluster, one command per volume:
  `aws ec2 delete-volume --volume-id <id> --profile <aws_profile_name> --region <aws_region>`.
  Never delete a volume that is `in-use` or that names another cluster.
- **Local.** `terraform destroy` deletes the k3d cluster. If the state is gone,
  `k3d cluster delete <k3d_cluster_name>` removes the containers and volumes.
- **Azure resource group will not delete.** A lock (`az lock list`) or a
  resource with a dependency outside the group. Remove the lock, or delete the
  named resource, then destroy again.

After any manual cleanup, run `terraform destroy -var-file=settings.tfvars`
once more so state and reality agree, and finish with step 4 or 5 to confirm
nothing is left.

## Needs a GoodData support ticket

Teardown problems are cloud and Kubernetes mechanics, not GoodData.CN faults, so
a ticket rarely applies. One exception: an Organization whose finalizer the
controller refuses to clear while the controller is healthy and logs an error
naming GoodData.CN.

## What to include

The last page of the destroy output, the Organization `describe` status, and
the organization controller log tail.

## Deeper investigation (observability on)

Not applicable; the observability stack is usually gone by this point.

## See also

- Family C for expired credentials during a long destroy.
- Family D for the Organization finalizer command.
