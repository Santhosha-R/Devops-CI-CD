#!/usr/bin/env bash
# Setup 2 — Gateway API CRDs + Envoy Gateway controller.
# TLS: the Envoy Service is an AWS NLB that TERMINATES TLS with the ACM cert (ACM_ARN).
# Envoy itself listens plain HTTP on :443 behind the NLB (the NLB already decrypted).
# Subnets are auto-discovered (public subnets tagged kubernetes.io/role/elb=1 by pre-setup/03).
set -euo pipefail
# demo config — 00-rbac-kubeconfig.sh writes pre-setup/demo.env from the domain you enter
_ENV="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/pre-setup/demo.env"; [ -f "$_ENV" ] && . "$_ENV"
DEMO_DOMAIN="${DEMO_DOMAIN:-hobbyez.com}"
: "${ACM_ARN:?export ACM_ARN=<the *.${DEMO_DOMAIN} ACM cert arn>}"

# 1. Gateway API standard CRDs (Gateway, HTTPRoute, ...) — only if absent
kubectl get crd httproutes.gateway.networking.k8s.io >/dev/null 2>&1 || \
  kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml

# 2. Envoy Gateway controller (CRDs already applied above)
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version v1.2.0 \
  -n envoy-gateway-system --create-namespace --skip-crds
kubectl -n envoy-gateway-system rollout status deploy/envoy-gateway --timeout=180s

# 3. EnvoyProxy (NLB + ACM) and the GatewayClass that points at it
kubectl apply -f - <<YAML
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata: { name: acm-proxy, namespace: envoy-gateway-system }
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyService:
        type: LoadBalancer
        externalTrafficPolicy: Cluster
        annotations:
          service.beta.kubernetes.io/aws-load-balancer-type: external
          service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: instance
          service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
          service.beta.kubernetes.io/aws-load-balancer-ssl-cert: ${ACM_ARN}
          service.beta.kubernetes.io/aws-load-balancer-ssl-ports: "443"
---
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata: { name: eg }
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef:
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: acm-proxy
    namespace: envoy-gateway-system
YAML

kubectl get gatewayclass
