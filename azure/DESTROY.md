# Azure Destroy Guide

## ⚠️ WARNING: PERMANENT DELETION (No undo)

## Quick Destroy
```bash
./destroy.sh  # Enhanced script handles most issues automatically
```

## Manual Steps (if script fails)

**Backup** (optional):
```bash
kubectl get organizations,secrets -n gooddata-cn -o yaml > backup.yaml
```

**Clean Stuck Namespaces**:
```bash
export NS=gooddata-cn  # or cluster-autoscaler, ingress-nginx
kubectl api-resources --verbs=list --namespaced -o name | xargs -n1 kubectl -n "$NS" get --ignore-not-found
kubectl -n "$NS" patch <kind>/<name> -p '{"metadata":{"finalizers":[]}}' --type=merge
```

**Manual Terraform Destroy**:
```bash
terraform destroy -var-file=terraform.tfvars -auto-approve
# Fix Public IP issues:
NODE_RG=$(az aks show --name gooddata-cn-poc --resource-group gooddata-cn-poc-rg --query nodeResourceGroup -o tsv)
az network lb delete --name kubernetes --resource-group "$NODE_RG" --yes
```

**Verify Cleanup**:
```bash
az resource list --resource-group gooddata-cn-poc-rg
rm -rf .terraform terraform.tfstate*
```

## Common Issues: Stuck namespaces, Public IP attached, State conflicts

**Time**: ~2-3 minutes
