# Azure Terraform Deployment - Destruction Guide

## ⚠️ **CRITICAL WARNING** ⚠️

**THIS WILL PERMANENTLY DELETE ALL RESOURCES AND DATA**

- All Azure infrastructure will be destroyed
- All data in PostgreSQL database will be lost
- All files in Azure Storage will be deleted
- All Kubernetes configurations will be removed
- **THERE IS NO UNDO OPERATION**

---

## 📋 **Pre-Destruction Checklist**

### **1. Data Backup (If Required)**
```bash
# Export GoodData.CN organizations (if needed)
kubectl get organizations -n gooddata-cn -o yaml > gooddata-organizations-backup.yaml

# Export important secrets (if needed)
kubectl get secrets -n gooddata-cn -o yaml > gooddata-secrets-backup.yaml

# Export PostgreSQL data (if required)
# Note: This requires database access credentials
```

### **2. Verify Current State**
```bash
# Check current Terraform state
terraform state list

# Verify Azure resources
az resource list --resource-group gooddata-cn-rg --output table

# Check AKS cluster status
kubectl get nodes
kubectl get pods --all-namespaces
```

---

## 🗑️ **DESTRUCTION PROCEDURE**

### **Step 1: Kubernetes Resource Cleanup (Optional but Recommended)**

```bash
# Remove any PersistentVolumeClaims that might prevent deletion
kubectl delete pvc --all -n gooddata-cn

# Remove any LoadBalancer services that might have external dependencies
kubectl delete svc --all -n gooddata-cn

# Remove test organization
kubectl delete -f test-organization.yaml

# Clean up any manual ingress resources
kubectl delete ingress --all -n gooddata-cn
```

### **Step 2: Terraform Destroy**

```bash
# Navigate to Azure terraform directory
cd /path/to/gooddata-cn-terraform/azure

# Review what will be destroyed
terraform plan -destroy

# Execute destruction (requires confirmation)
terraform destroy

# Alternative: Auto-approve (USE WITH EXTREME CAUTION)
# terraform destroy -auto-approve
```

### **Step 3: Manual Cleanup Verification**

```bash
# Verify resource group is empty
az resource list --resource-group gooddata-cn-rg --output table

# Check for any remaining resources
az resource list --query "[?resourceGroup=='gooddata-cn-rg']" --output table

# Verify AKS node resource group is also cleaned up
az resource list --resource-group MC_gooddata-cn-rg_gooddata-cn_centralus --output table
```

### **Step 4: Complete Resource Group Cleanup (If Needed)**

```bash
# If any resources remain, manually delete the entire resource group
az group delete --name gooddata-cn-rg --yes --no-wait

# Also delete the AKS-managed resource group if it exists
az group delete --name MC_gooddata-cn-rg_gooddata-cn_centralus --yes --no-wait
```

---

## ⏱️ **Expected Destruction Timeline**

| Component | Estimated Time |
|-----------|----------------|
| **Kubernetes Resources** | 2-5 minutes |
| **Application Gateway** | 3-8 minutes |
| **AKS Cluster** | 5-15 minutes |
| **PostgreSQL Database** | 3-10 minutes |
| **Storage Account** | 1-3 minutes |
| **Virtual Network** | 1-5 minutes |
| **Resource Group** | 1-2 minutes |
| **Total Estimated Time** | **15-45 minutes** |

---

## 🔍 **Verification Steps**

### **1. Terraform State Verification**
```bash
# Check terraform state is clean
terraform state list
# Should return empty or show no resources

# Verify terraform state file
ls -la terraform.tfstate*
```

### **2. Azure Resource Verification**
```bash
# Verify no resources exist in resource group
az resource list --resource-group gooddata-cn-rg
# Should return empty array: []

# Verify resource group is deleted
az group exists --name gooddata-cn-rg
# Should return: false

# Check for any orphaned resources
az resource list --query "[?contains(name, 'gooddata-cn')]" --output table
```

### **3. Cost Verification**
```bash
# Check Azure cost analysis (after 24-48 hours)
az consumption usage list --top 10 --output table

# Verify no ongoing charges for deleted resources
# Monitor Azure billing portal for 2-3 days
```

---

## 🚨 **Troubleshooting Common Issues**

### **Issue 1: Terraform Destroy Fails on Dependencies**
```bash
# Error: Resource still has dependencies
# Solution: Manually delete problematic resources first

# For AKS clusters with persistent volumes
kubectl delete pv --all

# For Application Gateway with dependencies
az network application-gateway delete --name gooddata-cn-appgw --resource-group gooddata-cn-rg

# Then retry terraform destroy
terraform destroy -target=specific_resource
```

### **Issue 2: Resource Group Won't Delete**
```bash
# Check for hidden or locked resources
az resource list --resource-group gooddata-cn-rg --include-hidden

# Check for resource locks
az lock list --resource-group gooddata-cn-rg

# Remove locks if found
az lock delete --name <lock-name> --resource-group gooddata-cn-rg

# Force delete resource group
az group delete --name gooddata-cn-rg --force-deletion-types Microsoft.Compute/virtualMachines,Microsoft.Compute/virtualMachineScaleSets
```

### **Issue 3: AKS Node Resource Group Issues**
```bash
# Find the exact node resource group name
az aks show --name gooddata-cn --resource-group gooddata-cn-rg --query nodeResourceGroup

# Delete the node resource group manually
az group delete --name <node-resource-group-name> --yes
```

### **Issue 4: Storage Account Won't Delete**
```bash
# Check for legal hold or retention policies
az storage account show --name <storage-account-name> --resource-group gooddata-cn-rg

# Remove any container-level policies
az storage container list --account-name <storage-account-name>

# Force delete containers
az storage container delete --name <container-name> --account-name <storage-account-name>
```

---

## 💰 **Cost Impact**

### **Immediate Cost Savings**
After successful destruction, you should see immediate cost reductions for:
- ✅ **AKS Cluster**: ~$150-300/month (depending on node size)
- ✅ **Application Gateway**: ~$20-40/month
- ✅ **PostgreSQL Database**: ~$50-150/month
- ✅ **Storage Account**: ~$5-20/month
- ✅ **Network Resources**: ~$10-30/month

### **Total Monthly Savings**: ~$235-540/month

---

## 📁 **File Cleanup**

### **Local Files to Clean Up**
```bash
# Remove Terraform state files (after confirming destruction)
rm terraform.tfstate*
rm .terraform.lock.hcl
rm -rf .terraform/

# Remove temporary files
rm -f gooddata-selfsigned.crt
rm -f gooddata-selfsigned.key
rm -f auth-agic-ingress.yaml
rm -f org-agic-ingress.yaml
rm -f test-simple-ingress.yaml

# Clean up backup files (if created)
rm -f gooddata-organizations-backup.yaml
rm -f gooddata-secrets-backup.yaml
```

---

## ✅ **Post-Destruction Checklist**

- [ ] Terraform state is empty (`terraform state list` returns nothing)
- [ ] Azure resource group is deleted (`az group exists --name gooddata-cn-rg` returns false)
- [ ] No unexpected Azure charges appear in billing (check after 24-48 hours)
- [ ] Local terraform state files are cleaned up
- [ ] Temporary certificates and configuration files are removed
- [ ] Backup files are stored securely (if created)

---

## 🔄 **Re-deployment Notes**

If you need to redeploy in the future:

1. **Use the same terraform configuration** - all files are preserved
2. **Update IP addresses** in `test-organization.yaml` (new Application Gateway will have different IP)
3. **Regenerate SSL certificates** if using self-signed certificates
4. **Review variable values** in `terraform.tfvars` before redeployment

---

## 📞 **Support**

If you encounter issues during destruction:

1. **Check Azure Activity Log** for detailed error messages
2. **Review Terraform destroy logs** for specific resource failures  
3. **Use Azure CLI commands** for manual resource deletion as last resort
4. **Contact Azure Support** for locked or corrupted resources

---

**⚠️ REMEMBER: Always double-check you're destroying the correct environment before proceeding!**
