# Azure GoodData.CN Troubleshooting

## Health Check
```bash
kubectl get ingress,certificates,pods -n gooddata-cn
curl -k -I https://org.{EXTERNAL_IP}.sslip.io
```

## Issues & Fixes

**1. URL "Not Working"**: Returns HTTP 200, shows setup page (normal for fresh install)
```bash
curl -k -s -o /dev/null -w "%{http_code}" https://org.{IP}.sslip.io  # Should be 200
```

**2. No External IP**: 
```bash
kubectl get svc -n ingress-nginx
kubectl describe svc ingress-nginx-controller -n ingress-nginx
```

**3. Certificates Not Ready**: 
```bash
kubectl get challenges -A
kubectl logs -n cert-manager deployment/cert-manager
```

**4. Pods Crashing**: 
```bash
kubectl get pods -n gooddata-cn | grep -v Running
kubectl describe pod {pod-name} -n gooddata-cn
```

**5. Autoscaler Issues**: 
```bash
kubectl logs -n cluster-autoscaler deployment/cluster-autoscaler
# Fix: Check RBAC permissions in aks-autoscaler-rbac.tf
```

## Recovery
```bash
# Restart
kubectl rollout restart deployment -n gooddata-cn ingress-nginx

# Fix stuck namespaces
export NS=gooddata-cn
kubectl api-resources --verbs=list --namespaced -o name | xargs -n1 kubectl -n "$NS" get --ignore-not-found
kubectl -n "$NS" patch <resource> -p '{"metadata":{"finalizers":[]}}' --type=merge

# Certificate refresh
kubectl delete certificate gooddata-cn-org-tls gooddata-cn-auth-tls -n gooddata-cn
```

## Expected: 32 pods running, 2 ingresses with external IP, 2 certs ready, URLs return HTTP 200
