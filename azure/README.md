# Azure GoodData.CN Deployment

## Quick Start
```bash
# Prerequisites: az login (dev containers include all tools)
cp terraform.tfvars.example terraform.tfvars
# Edit: subscription_id, location, deployment_name
terraform init && terraform plan && terraform apply
./test-connectivity.sh

# Create first organization (interactive setup)
../create-org.sh
```

## Config (terraform.tfvars)
- `subscription_id` - Azure subscription
- `location = "centralus"` 
- `deployment_name = "gooddata-cn-poc"`
- `aks_node_vm_size = "Standard_D2ps_v6"`

## Architecture
AKS + nginx Ingress + PostgreSQL + Storage + Let's Encrypt TLS

## URLs
- Org: https://org.{external_ip}.sslip.io
- Auth: https://auth.{external_ip}.sslip.io

## Organization Setup
After successful terraform deployment, create your first organization:
```bash
../create-org.sh
# Interactive script prompts for:
# - Organization ID (default: test)
# - Organization name (default: Test, Inc.)
# - Hostname: org.{external_ip}.sslip.io
# - Admin username/password
# - First user email/password
```
Script automatically:
- Creates Kubernetes Organization resource
- Sets up first admin user
- Configures authentication
- Provides login URL and bearer token

## Issues
1. No external IP: `kubectl get svc -n ingress-nginx`
2. Certificates pending: `kubectl get challenges -A`
3. Pods crashing: `kubectl describe pod -n gooddata-cn`

## Destroy
```bash
# Complete destruction (auto-approve mode)
./destroy.sh

# Individual sections
./destroy.sh terraform    # Only run terraform destroy with auto-approve
./destroy.sh kubernetes   # Only clean up stuck namespaces  
./destroy.sh verify       # Only verify destruction completion
./destroy.sh help         # Show usage options

# If terraform hangs, script automatically runs namespace cleanup
# Manual cleanup if needed:
export NS=gooddata-cn
kubectl api-resources --verbs=list --namespaced -o name | xargs -n1 kubectl -n "$NS" get --ignore-not-found
kubectl -n "$NS" patch <kind>/<name> -p '{"metadata":{"finalizers":[]}}' --type=merge
```

## Cost: ~$133/month (dev)
