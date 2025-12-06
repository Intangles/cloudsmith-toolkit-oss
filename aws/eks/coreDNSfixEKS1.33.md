# CoreDNS Resolution Issues After EKS 1.33 + AL2023 Upgrade

This document outlines the common issues and solutions for CoreDNS DNS resolution problems after upgrading to EKS 1.33 with Amazon Linux 2023.

## Likely Root Causes

### 1. CoreDNS Version Incompatibility

EKS 1.33 requires CoreDNS v1.11.3 or later.

**Check current version:**
```bash
kubectl get deployment coredns -n kube-system -o jsonpath='{.spec.template.spec.containers[0].image}'
```

**Fix - Update CoreDNS add-on:**
```bash
aws eks update-addon --cluster-name <cluster-name> --addon-name coredns --resolve-conflicts OVERWRITE
```

### 2. ndots Configuration Issue (Most Common with AL2023)

AL2023 changed default DNS behavior. This is especially problematic if the database service uses short names.

**Check resolv.conf:**
```bash
kubectl exec -it <any-pod> -- cat /etc/resolv.conf
```

**Fix - Adjust ndots in pod spec:**
```yaml
spec:
  dnsConfig:
    options:
      - name: ndots
        value: "2"
```

### 3. CoreDNS ConfigMap Corruption/Reset

The upgrade may have reset custom CoreDNS configurations.

**Check ConfigMap:**
```bash
kubectl get configmap coredns -n kube-system -o yaml
```

**Fix - Ensure proper Corefile configuration:**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health
        kubernetes cluster.local in-addr.arpa ip6.arpa {
          pods insecure
          fallthrough in-addr.arpa ip6.arpa
        }
        prometheus :9153
        forward . /etc/resolv.conf
        cache 30
        loop
        reload
        loadbalance
    }
```

### 4. Headless Service DNS Issue

If your database uses a headless service, verify the configuration.

**Check service and endpoints:**
```bash
kubectl get svc <database-service> -o yaml
kubectl get endpoints <database-service>
```

Ensure `clusterIP: None` is set and endpoints are populated.

---

## Diagnostic Steps

```bash
# 1. Check CoreDNS pods are running
kubectl get pods -n kube-system -l k8s-app=kube-dns

# 2. Check CoreDNS logs
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=100

# 3. Test DNS resolution from a debug pod
kubectl run dnsutils --image=tutum/dnsutils --rm -it -- nslookup <database-service>.<namespace>.svc.cluster.local

# 4. Check if database service exists
kubectl get svc -A | grep <database-name>

# 5. Verify endpoints
kubectl get endpoints <database-service> -n <namespace>
```

---

## Quick Fix Checklist

| Step | Command |
|------|---------|
| Restart CoreDNS | `kubectl rollout restart deployment coredns -n kube-system` |
| Update CoreDNS add-on | `aws eks update-addon --cluster-name <name> --addon-name coredns` |
| Check VPC CNI | `aws eks update-addon --cluster-name <name> --addon-name vpc-cni` |
| Verify kube-proxy | `aws eks update-addon --cluster-name <name> --addon-name kube-proxy` |

---

## Recommended Fix Sequence

Based on the AL2023 upgrade, run this sequence:

```bash
# Update all EKS add-ons to compatible versions
aws eks update-addon --cluster-name <cluster-name> --addon-name coredns --resolve-conflicts OVERWRITE
aws eks update-addon --cluster-name <cluster-name> --addon-name kube-proxy --resolve-conflicts OVERWRITE
aws eks update-addon --cluster-name <cluster-name> --addon-name vpc-cni --resolve-conflicts OVERWRITE

# Restart CoreDNS
kubectl rollout restart deployment coredns -n kube-system
```

After completing these steps, remove the hardcoded IPs from the configuration and test DNS resolution again.

---

## Additional Resources

- [AWS EKS Add-ons Documentation](https://docs.aws.amazon.com/eks/latest/userguide/eks-add-ons.html)
- [CoreDNS Kubernetes Plugin](https://coredns.io/plugins/kubernetes/)
- [Amazon Linux 2023 Release Notes](https://docs.aws.amazon.com/linux/al2023/release-notes/)