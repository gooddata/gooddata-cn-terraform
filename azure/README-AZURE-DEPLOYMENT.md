# Azure Deployment Guide for GoodData.CN

This document provides specific guidance for deploying GoodData.CN on Microsoft Azure using Terraform.

## Prerequisites

### Azure Subscription and Permissions
- Active Azure subscription
- Sufficient permissions to create resources in Azure (Contributor role or higher)
- Azure CLI installed and configured (`az login`)

### Required Tools

**If using Dev Containers (Recommended):**
All tools are pre-configured in the development container including Azure CLI, Terraform, kubectl, and Helm.

**Manual Installation:**
- Terraform >= 1.0
- kubectl
- Azure CLI
- tinkey (version 1.11.0 or newer)
- Java Runtime Environment (for tinkey)

### Tinkey Installation
```bash
# Install Java if not already available
brew install openjdk@21
sudo ln -sfn /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk /Library/Java/JavaVirtualMachines/openjdk-21.jdk

# Install tinkey
TINKEY_VERSION="1.11.0"
curl -fsSL -o /tmp/tinkey.tgz https://storage.googleapis.com/tinkey/tinkey-${TINKEY_VERSION}.tar.gz
sudo tar -xzf /tmp/tinkey.tgz -C /usr/local/bin tinkey tinkey_deploy.jar
sudo chmod +x /usr/local/bin/tinkey
rm /tmp/tinkey.tgz
```

## Common Issues and Troubleshooting

### Azure Quota Limitations

**⚠️ IMPORTANT: vCPU Quota Issues**

If you encounter errors like:
```
Error: creating Kubernetes Cluster ... Insufficient regional vcpu quota left for location centralus. left regional vcpu quota 10, requested quota 12.
```

This indicates that your Azure subscription has reached its vCPU quota limit for the selected region. Here's how to resolve this:

#### 1. Check Current Quota Usage
```bash
# Check current vCPU usage and limits
az vm list-usage --location centralus --output table

# Check specific quota for the VM family you're using
az vm list-skus --location centralus --size Standard_D --output table
```

#### 2. Reduce Resource Requirements
Modify your `terraform.tfvars` file to use smaller VM sizes or fewer nodes:

```hcl
# Reduce AKS node size and count
aks_node_vm_size = "Standard_D2as_v6"  # 2 vCPUs per node instead of 4
aks_max_nodes    = 5                  # Reduce max nodes
aks_min_nodes    = 3                  # Reduce min nodes

# Also reduce PostgreSQL size if needed
postgresql_sku_name = "GP_Standard_D2as_v6"  # 2 vCPUs instead of 4
```

#### 3. Request Quota Increase
If you need more resources, request a quota increase:

1. Go to Azure Portal → Subscriptions → Usage + quotas
2. Search for "Standard DSv3 Family vCPUs" (or your VM family)
3. Click "Request increase"
4. Fill out the support request with your justification
5. Wait for approval (can take 1-3 business days)

#### 4. Use Different Azure Region
Some regions have higher default quotas. Consider deploying to:
- East US
- West US 2
- North Europe
- West Europe

Update your `terraform.tfvars`:
```hcl
azure_location = "East US"
```

### AKS Network Permissions

If the LoadBalancer service fails to get an external IP, ensure the AKS cluster has proper network permissions:

```bash
# Get AKS cluster identity
AKS_IDENTITY=$(az aks show --name <cluster-name> --resource-group <rg-name> --query "identity.principalId" -o tsv)

# Grant Network Contributor role
az role assignment create \
  --assignee $AKS_IDENTITY \
  --role "Network Contributor" \
  --scope "/subscriptions/<subscription-id>/resourceGroups/<rg-name>"
```

### Storage Access Issues

If you encounter storage access errors:
1. Ensure private endpoints are properly configured
2. Verify DNS resolution is working
3. Check that containers are created after private endpoint is ready

### PostgreSQL Connection Issues

Common PostgreSQL issues:
- Ensure `public_network_access_enabled = false` when using VNet integration
- Verify DNS zone linking is complete before server creation
- Check that the subnet is properly delegated to PostgreSQL

## Resource Sizing Guidelines

### Development/Testing Environment
```hcl
# Minimal resources for testing
aks_node_vm_size     = "Standard_D4ps_v6"  # 2 vCPUs, 8GB RAM
aks_max_nodes        = 5
aks_min_nodes        = 3 # this is required minimum
postgresql_sku_name  = "GP_Standard_D2ads_v5"  # 2 vCPUs, 8GB RAM
postgresql_storage_mb = 32768  # 32GB
```

**Total vCPU Requirements:** ~8-10 vCPUs

### Production Environment
```hcl
# Production-ready resources ** NOTE THIS IS MINIMUM SUGGESTED
aks_node_vm_size     = "Standard_D4ps_v6"  # 4 vCPUs, 16GB RAM
aks_max_nodes        = 5
aks_min_nodes        = 3
postgresql_sku_name  = "GP_Standard_D4ads_v5"  # 4 vCPUs, 16GB RAM
postgresql_storage_mb = 102400  # 100GB
```

**Total vCPU Requirements:** ~16-24 vCPUs

## Cost Optimization Tips

1. **Use B-series VMs for development**: `Standard_B2ms` (2 vCPUs, 8GB RAM) for cost savings
2. **Enable auto-scaling**: Set appropriate min/max node counts to scale with demand
3. **Use Azure Reserved Instances**: For predictable workloads, reserve instances for 1-3 years
4. **Monitor resource usage**: Use Azure Cost Management to track spending
5. **Stop/Start development environments**: Consider automation to stop resources during off-hours

## Deployment Steps

1. **Configure variables**: Copy `terraform.tfvars.example` to `terraform.tfvars` and customize
2. **Initialize Terraform**: `terraform init`
3. **Plan deployment**: `terraform plan`
4. **Deploy**: `terraform apply`
5. **Verify**: Check that all pods are running and services are accessible

## Destroying Infrastructure

### Enhanced Destroy Script

The `destroy.sh` script includes advanced cleanup logic to handle common Azure destruction issues:

```bash
./destroy.sh
```

**Features:**
- **Automatic namespace cleanup**: Handles stuck Kubernetes namespaces with finalizers
- **Public IP cleanup**: Resolves LoadBalancer IP attachment issues
- **Progressive retry logic**: Automatically retries with incremental fixes
- **Backup creation**: Optional backup of Kubernetes resources before destruction
- **Color-coded logging**: Clear status indicators throughout the process

### Manual Namespace Cleanup (if needed)

If you encounter stuck namespaces during destruction, use this approach:

```bash
export ORG_NS=gooddata-cn  # or cluster-autoscaler, ingress-nginx

# Find blocking resources
kubectl api-resources --verbs=list --namespaced -o name \
| xargs -n1 kubectl -n "$ORG_NS" get --ignore-not-found

# Remove finalizers on blocking objects (last resort)
kubectl -n "$ORG_NS" patch <kind>/<name> -p '{"metadata":{"finalizers":[]}}' --type=merge
```

**Common stuck resources:**
- `organizations.controllers.gooddata.com` (in gooddata-cn namespace)
- LoadBalancer services (in ingress-nginx namespace)
- PersistentVolumeClaims with storage finalizers

### Troubleshooting Destroy Issues

**Public IP cannot be deleted:**
```bash
# Find the LoadBalancer using the public IP
NODE_RG=$(az aks show --name gooddata-cn-poc --resource-group gooddata-cn-poc-rg --query nodeResourceGroup -o tsv)
az network lb delete --name kubernetes --resource-group "$NODE_RG" --yes
```

**Terraform state inconsistencies:**
```bash
# Refresh state and retry
terraform refresh -var-file=terraform.tfvars
terraform destroy -var-file=terraform.tfvars
```

## Support

For deployment issues:
1. Check this troubleshooting guide first
2. Review Terraform state and logs
3. Check Azure Activity Log for detailed error messages
4. Contact your Azure support team for quota-related issues
