#!/usr/bin/env bash
# Setup 3 — Istio (base + istiod + ingress gateway), via Helm (no istioctl).
# TLS: the ingress-gateway Service is an AWS NLB that TERMINATES TLS with the ACM cert.
# NLB :443 decrypts ACM TLS and forwards plain HTTP to the gateway's app listener (:80).
# NLB :80 forwards to the same :80 listener, so the bare http:// URL also opens. Subnets auto-discovered.
set -euo pipefail
# demo config — 00-rbac-kubeconfig.sh writes pre-setup/demo.env from the domain you enter
_ENV="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/pre-setup/demo.env"; [ -f "$_ENV" ] && . "$_ENV"
DEMO_DOMAIN="${DEMO_DOMAIN:-hobbyez.com}"
: "${ACM_ARN:?export ACM_ARN=<the *.${DEMO_DOMAIN} ACM cert arn>}"
VER="${ISTIO_VERSION:-1.24.0}"

helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null 2>&1 || true
helm repo update istio >/dev/null

# control plane
kubectl create namespace istio-system --dry-run=client -o yaml | kubectl apply -f -
# install once (guarded): re-upgrading istio-base conflicts with istiod's server-side ownership of
# the validation webhook's failurePolicy, so skip if the release is already present.
helm -n istio-system status istio-base >/dev/null 2>&1 || helm install istio-base istio/base  -n istio-system --version "$VER" --set defaultRevision=default
helm -n istio-system status istiod     >/dev/null 2>&1 || helm install istiod     istio/istiod -n istio-system --version "$VER" --wait

# ingress gateway — its own injection-enabled namespace; NLB terminates ACM TLS on :443 -> :80
kubectl create namespace istio-ingress --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace istio-ingress istio-injection=enabled --overwrite
helm upgrade --install istio-ingressgateway istio/gateway -n istio-ingress --version "$VER" --skip-schema-validation -f - <<YAML
labels:
  istio: ingressgateway
service:
  type: LoadBalancer
  ports:
    - name: status-port
      port: 15021
      targetPort: 15021
    - name: https
      port: 443
      targetPort: 80       # envoy ingress listener (istio 1.24 listens on :80, not 8080)
    - name: http
      port: 80
      targetPort: 80       # plain http:// -> same envoy app listener (bare URL opens, unencrypted)
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: instance
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
    service.beta.kubernetes.io/aws-load-balancer-ssl-cert: ${ACM_ARN}
    service.beta.kubernetes.io/aws-load-balancer-ssl-ports: "443"
YAML

kubectl -n istio-system  rollout status deploy/istiod
kubectl -n istio-ingress rollout status deploy/istio-ingressgateway
kubectl get svc -n istio-ingress istio-ingressgateway
