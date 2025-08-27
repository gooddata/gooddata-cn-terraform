# Azure GoodData.CN Troubleshooting Guide

## Current Status: ✅ SYSTEM IS WORKING CORRECTLY

### Initial Problem Investigation
**URL**: https://org.172.173.99.209.sslip.io
**Status**: ✅ WORKING - Returns HTTP 200 with GoodData.CN Home UI

## Compressed test script
```
./test-connectivity.sh | grep -E "(Testing|status:|✅|❌|📋)"
```

## Troubleshooting Results

### 1. ✅ Ingress Status - HEALTHY
```
NAME              CLASS   HOSTS                          ADDRESS          PORTS     AGE
gooddata-cn-dex   nginx   auth.172.173.99.209.sslip.io   172.173.99.209   80, 443   89m
gooddata-cn-org   nginx   org.172.173.99.209.sslip.io    172.173.99.209   80, 443   80m
```
- Both ingress resources are working with assigned external IP
- nginx ingress class is properly configured

### 2. ✅ TLS Certificates - READY
```
NAME                   READY   SECRET                 AGE
gooddata-cn-auth-tls   True    gooddata-cn-auth-tls   89m
gooddata-cn-org-tls    True    gooddata-cn-org-tls    80m
```
- Let's Encrypt certificates are issued and valid
- Certificate expiry: 2025-11-25 (valid for 3 months)

### 3. ✅ Backend Services - HEALTHY
```
NAME                      TYPE        CLUSTER-IP   PORT(S)   SELECTOR
gooddata-cn-api-gateway   ClusterIP   10.2.0.76    9092/TCP  app.kubernetes.io/component=apiGateway
```
- Service is accessible on port 9092
- Internal health check returns HTTP 200

### 4. ✅ Pods Status - ALL RUNNING
```
gooddata-cn-api-gateway-7d789bc5b7-6mcl5               1/1     Running
gooddata-cn-metadata-api-6dc5576cd5-lmdsk              1/1     Running  
gooddata-cn-organization-controller-85bcbbcf4b-bw52v   1/1     Running
```
- All critical pods are healthy and running
- No crashes or restart loops detected

### 5. ✅ External Access - WORKING
- External URL returns HTTP 200
- Serves complete GoodData.CN Home UI HTML
- TLS certificates are working properly

## Root Cause Analysis

**The URL is working correctly!** 

What you're seeing is the **initial GoodData.CN setup/bootstrap page**, not an error. This is the expected behavior for a fresh installation that hasn't been configured yet.

## What the User Is Seeing

The organization URL shows the GoodData.CN Home UI which includes:
- JavaScript application bundle
- CSS stylesheets  
- Initial setup interface
- Commit hash: `bff93447`

This indicates the system is ready for **initial organization setup**.

## Next Steps for Users

### 1. Complete Initial Setup
1. Open your browser and navigate to: https://org.172.173.99.209.sslip.io
2. You should see the GoodData.CN setup wizard
3. Follow the on-screen instructions to:
   - Create your first organization
   - Set up admin user credentials
   - Configure basic settings

### 2. Authentication Setup
1. Authentication URL: https://auth.172.173.99.209.sslip.io
2. This handles OAuth/OIDC authentication via Dex

### 3. Verify Setup Complete
After setup, the organization URL will show your configured organization instead of the bootstrap page.

## Common Misunderstandings

❌ **Misconception**: "The URL is not working" (returns empty/error page)
✅ **Reality**: The URL works perfectly - it shows the setup page for new installations

❌ **Misconception**: "Something is broken because I see HTML instead of a dashboard"  
✅ **Reality**: Fresh installations show setup UI until first organization is created

## Infrastructure Health Check Commands

```bash
# Check ingress status
kubectl get ingress -n gooddata-cn

# Check certificate status  
kubectl get certificates -n gooddata-cn

# Check pod health
kubectl get pods -n gooddata-cn

# Test internal connectivity
kubectl exec -n gooddata-cn deployment/gooddata-cn-api-gateway -- curl -s -o /dev/null -w "%{http_code}" http://localhost:9092/health

# Test external access
curl -k -I https://org.172.173.99.209.sslip.io
```

## Architecture Overview

```
Internet → Azure LoadBalancer (172.173.99.209) → nginx Ingress → GoodData.CN Services
         ↓
    Let's Encrypt TLS
```

**Components:**
- Azure Load Balancer with public IP `172.173.99.209`
- nginx Ingress Controller (replaces Azure Application Gateway)
- cert-manager with Let's Encrypt for automatic TLS
- GoodData.CN application stack with PostgreSQL backend

## Performance Notes

- **Total deployment time**: ~27 minutes
- **Pod count**: 32 active pods
- **Resource sizing**: POC/development profile
- **Auto-scaling**: Enabled (3-5 nodes)

## Recovery Procedures

**Full system restart:**
```bash
kubectl rollout restart deployment -n gooddata-cn
kubectl rollout restart deployment -n ingress-nginx
```

**Certificate refresh:**
```bash
kubectl delete certificate gooddata-cn-org-tls -n gooddata-cn
kubectl delete certificate gooddata-cn-auth-tls -n gooddata-cn
# Certificates will be recreated automatically
```

**Stuck namespace cleanup (common issue):**
```bash
export ORG_NS=gooddata-cn  # or cluster-autoscaler, ingress-nginx

# Find blocking resources
kubectl api-resources --verbs=list --namespaced -o name \
| xargs -n1 kubectl -n "$ORG_NS" get --ignore-not-found

# Remove finalizers as last resort
kubectl -n "$ORG_NS" patch <kind>/<name> -p '{"metadata":{"finalizers":[]}}' --type=merge
```

## Infrastructure Destruction

**Enhanced destroy script** (handles most common issues automatically):
```bash
./destroy.sh
```

The destroy script includes automatic cleanup for:
- Stuck Kubernetes namespaces with finalizers
- Public IP attachment issues with LoadBalancers
- Progressive retry logic with incremental fixes
- Optional backup creation before destruction

**Manual cleanup for persistent issues:**
```bash
# Remove stuck public IP
NODE_RG=$(az aks show --name gooddata-cn-poc --resource-group gooddata-cn-poc-rg --query nodeResourceGroup -o tsv)
az network lb delete --name kubernetes --resource-group "$NODE_RG" --yes

# Terraform state refresh
terraform refresh -var-file=terraform.tfvars
terraform destroy -var-file=terraform.tfvars
```

## Support Information

**Installation Details:**
- Platform: Azure AKS (Central US)
- Resource Group: `gooddata-cn-poc-rg`
- Cluster: `gooddata-cn-poc`
- GoodData.CN Version: 3.42.0
- nginx Ingress: 4.11.3
- Deployment Date: 2025-08-27

---

**Conclusion**: The system is functioning perfectly. The user needs to complete the initial organization setup via the web interface.
