#!/bin/bash

# Storage Test Script for GoodData.CN Azure Deployment
echo "=== GoodData.CN Storage Test ==="
echo "Testing storage account: gooddatacnpoc4f49c5"
echo "Checking blob containers: quiver-cache, quiver-datasource-fs, exports"
echo ""

# First, let's create a test pod that can access the storage
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: storage-test
  namespace: gooddata-cn
spec:
  containers:
  - name: azure-cli
    image: mcr.microsoft.com/azure-cli:latest
    command: ["sleep", "3600"]
    env:
    - name: AZURE_STORAGE_ACCOUNT
      value: "gooddatacnpoc4f49c5"
    - name: AZURE_STORAGE_AUTH_MODE
      value: "login"
  restartPolicy: Never
EOF

echo "Waiting for pod to be ready..."
kubectl wait --for=condition=Ready pod/storage-test -n gooddata-cn --timeout=120s

if [ $? -eq 0 ]; then
    echo ""
    echo "=== Testing Azure Storage Access ==="
    
    # Test 1: Check if we can access storage account
    echo "1. Testing storage account access..."
    kubectl exec -n gooddata-cn storage-test -- az storage account show \
        --name gooddatacnpoc4f49c5 \
        --resource-group gooddata-cn-poc-rg \
        --query "name" --output tsv 2>/dev/null
    
    if [ $? -eq 0 ]; then
        echo "✅ Storage account accessible"
    else
        echo "❌ Storage account not accessible"
    fi
    
    # Test 2: List containers
    echo ""
    echo "2. Listing storage containers..."
    kubectl exec -n gooddata-cn storage-test -- az storage container list \
        --account-name gooddatacnpoc4f49c5 \
        --auth-mode login \
        --query "[].name" --output tsv 2>/dev/null
    
    # Test 3: Check each container contents
    for container in quiver-cache quiver-datasource-fs exports; do
        echo ""
        echo "3. Checking container: $container"
        echo "   Listing blobs in $container..."
        
        blob_count=$(kubectl exec -n gooddata-cn storage-test -- az storage blob list \
            --account-name gooddatacnpoc4f49c5 \
            --container-name $container \
            --auth-mode login \
            --query "length(@)" --output tsv 2>/dev/null)
        
        if [ $? -eq 0 ]; then
            echo "   ✅ Container $container accessible - Contains $blob_count blobs"
            
            if [ "$blob_count" -gt 0 ]; then
                echo "   📁 Files in $container:"
                kubectl exec -n gooddata-cn storage-test -- az storage blob list \
                    --account-name gooddatacnpoc4f49c5 \
                    --container-name $container \
                    --auth-mode login \
                    --query "[].{Name:name, Size:properties.contentLength, LastModified:properties.lastModified}" \
                    --output table 2>/dev/null
            else
                echo "   📭 Container $container is empty"
            fi
        else
            echo "   ❌ Cannot access container $container"
        fi
    done
    
    # Test 4: Test file creation in quiver-cache
    echo ""
    echo "4. Testing file creation in quiver-cache..."
    test_file="test-$(date +%s).txt"
    echo "Creating test file: $test_file"
    
    kubectl exec -n gooddata-cn storage-test -- bash -c "echo 'Storage test at $(date)' | az storage blob upload \
        --account-name gooddatacnpoc4f49c5 \
        --container-name quiver-cache \
        --name $test_file \
        --auth-mode login \
        --file /dev/stdin" 2>/dev/null
    
    if [ $? -eq 0 ]; then
        echo "   ✅ File creation successful!"
        echo "   📝 Verifying file content..."
        kubectl exec -n gooddata-cn storage-test -- az storage blob download \
            --account-name gooddatacnpoc4f49c5 \
            --container-name quiver-cache \
            --name $test_file \
            --auth-mode login \
            --file /dev/stdout 2>/dev/null
        
        echo ""
        echo "   🗑️ Cleaning up test file..."
        kubectl exec -n gooddata-cn storage-test -- az storage blob delete \
            --account-name gooddatacnpoc4f49c5 \
            --container-name quiver-cache \
            --name $test_file \
            --auth-mode login 2>/dev/null
    else
        echo "   ❌ File creation failed"
    fi
    
else
    echo "❌ Failed to create test pod"
fi

echo ""
echo "=== Cleanup ==="
kubectl delete pod storage-test -n gooddata-cn --ignore-not-found

echo ""
echo "=== Storage Test Complete ==="
