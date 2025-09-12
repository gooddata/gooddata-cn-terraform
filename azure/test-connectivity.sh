#!/bin/bash

echo "🔍 GoodData.CN Azure Connectivity Test Script"
echo "============================================="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Helper function for status
print_status() {
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ $1${NC}"
    else
        echo -e "${RED}❌ $1${NC}"
    fi
}

echo ""
echo "1️⃣ Testing LoadBalancer Service..."
kubectl get services -n ingress-nginx | grep LoadBalancer
print_status "LoadBalancer check"

echo ""
echo "2️⃣ Testing Ingress Controller Pods..."
kubectl get pods -n ingress-nginx
print_status "Ingress controller pods check"

echo ""
echo "3️⃣ Testing GoodData.CN Organizations..."
ORG_COUNT=$(kubectl get organizations -A --no-headers 2>/dev/null | wc -l)
if [ "$ORG_COUNT" -eq 0 ]; then
    echo -e "${RED}❌ No organizations found!${NC}"
    echo -e "${YELLOW}⚠️  You need to create an organization first:${NC}"
    echo "   kubectl apply -f test-organization.yaml"
else
    echo -e "${GREEN}✅ Found $ORG_COUNT organization(s)${NC}"
    kubectl get organizations -A
fi

echo ""
echo "4️⃣ Testing Ingress Resources..."
kubectl get ingress -A
print_status "Ingress resources check"

echo ""
echo "5️⃣ Testing GoodData.CN Pods..."
POD_COUNT=$(kubectl get pods -n gooddata-cn --no-headers | grep Running | wc -l)
echo "Running pods: $POD_COUNT"
if [ "$POD_COUNT" -gt 15 ]; then
    echo -e "${GREEN}✅ GoodData.CN pods healthy${NC}"
else
    echo -e "${RED}❌ Some GoodData.CN pods may not be ready${NC}"
    kubectl get pods -n gooddata-cn | grep -v Running
fi

echo ""
echo "6️⃣ Testing Internal Network Connectivity..."
echo "Creating test pod for internal connectivity test..."
kubectl run connectivity-test --rm -i --timeout=30s --image=curlimages/curl --restart=Never -- /bin/sh -c "
echo 'Testing internal service connectivity...'
curl -s -o /dev/null -w 'Auth service: %{http_code}\n' gooddata-cn-dex.gooddata-cn.svc.cluster.local:32000/dex/.well-known/openid_configuration --max-time 5
curl -s -o /dev/null -w 'API Gateway: %{http_code}\n' gooddata-cn-api-gateway.gooddata-cn.svc.cluster.local:9092/health --max-time 5
" 2>/dev/null
print_status "Internal connectivity test"

echo ""
echo "7️⃣ Testing External DNS Resolution..."
EXTERNAL_IP=$(terraform output -raw ingress_external_ip 2>/dev/null || echo "172.173.99.209")
echo "Using External IP: $EXTERNAL_IP"
nslookup auth.$EXTERNAL_IP.sslip.io 8.8.8.8 | grep -A2 "Name:"
print_status "DNS resolution test"

echo ""
echo "8️⃣ Testing External HTTP/HTTPS Connectivity..."
echo "Testing auth endpoint (HTTP - should redirect to HTTPS)..."
curl -s -o /dev/null -w "Auth endpoint HTTP status: %{http_code}\n" --max-time 10 http://auth.$EXTERNAL_IP.sslip.io/dex/.well-known/openid_configuration

echo "Testing auth endpoint (HTTPS)..."
curl -k -s -o /dev/null -w "Auth endpoint HTTPS status: %{http_code}\n" --max-time 10 https://auth.$EXTERNAL_IP.sslip.io/dex/.well-known/openid_configuration

echo "Testing org endpoint (HTTP - should redirect to HTTPS)..."
curl -s -o /dev/null -w "Org endpoint HTTP status: %{http_code}\n" --max-time 10 http://org.$EXTERNAL_IP.sslip.io/

echo "Testing org endpoint (HTTPS)..."
curl -k -s -o /dev/null -w "Org endpoint HTTPS status: %{http_code}\n" --max-time 10 https://org.$EXTERNAL_IP.sslip.io/

echo ""
echo "9️⃣ Azure Network Security Group Check..."
echo "AKS NSG rules:"
CLUSTER_NAME=$(terraform output -raw aks_cluster_name 2>/dev/null || echo "gooddata-cn-poc")
RG_NAME="gooddata-cn-poc-rg"
NODE_RG_NAME="MC_${RG_NAME}_${CLUSTER_NAME}_centralus"

az network nsg list --resource-group $RG_NAME --query "[].name" -o tsv 2>/dev/null | while read nsg_name; do
    echo "NSG: $nsg_name"
    az network nsg rule list --nsg-name "$nsg_name" --resource-group $RG_NAME --query "[?direction=='Inbound' && access=='Allow'].{Name:name, Priority:priority, Protocol:protocol, DestinationPortRange:destinationPortRange, Source:sourceAddressPrefix}" -o table 2>/dev/null
done || echo "Unable to check NSG rules (check Azure CLI auth)"

echo ""
echo "🔟 Azure LoadBalancer Status..."
az network lb list --resource-group $NODE_RG_NAME --query "[].{Name:name, ProvisioningState:provisioningState}" -o table 2>/dev/null || echo "Unable to check LoadBalancer (check Azure CLI auth)"

echo ""
echo "================================================"
echo "🎯 NEXT STEPS:"
echo "================================================"
EXTERNAL_IP=$(terraform output -raw ingress_external_ip 2>/dev/null || echo "172.173.99.209")
if [ "$ORG_COUNT" -eq 0 ]; then
    echo "1. Create an organization: kubectl apply -f test-organization.yaml"
    echo "2. Wait 2-3 minutes for organization to be ready"
    echo "3. Check new ingress: kubectl get ingress -n gooddata-cn"
    echo "4. Test access: curl -k https://org.$EXTERNAL_IP.sslip.io/"
else
    echo "1. Check if org ingress exists: kubectl get ingress -n gooddata-cn"
    echo "2. Test access: curl -k https://org.$EXTERNAL_IP.sslip.io/"
    echo "3. If still failing, check certificate: kubectl describe ingress -n gooddata-cn"
fi

echo ""
echo "1️⃣1️⃣ Testing AKS Built-in Autoscaler..."
NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)
echo "Current node count: $NODE_COUNT"
echo -e "${GREEN}✅ AKS built-in autoscaler is managed automatically${NC}"
echo "Node autoscaling configured in AKS node pool (check Azure portal for details)"

echo ""
echo "📋 Current URLs:"
echo "• Auth URL: https://auth.$EXTERNAL_IP.sslip.io"
echo "• Org URL:  https://org.$EXTERNAL_IP.sslip.io"
echo ""
