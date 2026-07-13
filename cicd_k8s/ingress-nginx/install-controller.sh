#!/usr/bin/env bash
# ingress-nginx controller (kubernetes/ingress-nginx — the community one), fronted by an AWS NLB.
# The NLB is provisioned by the AWS Load Balancer Controller (pre-setup/02), so that must be up.
#
# admissionWebhooks disabled: that webhook is called by the API server, and on kubeadm the API
# server (host-networked on the control-plane) can't reliably reach a webhook pod on a worker
# ("context deadline exceeded"). Disabling it means a malformed Ingress is rejected by the
# controller at reload time instead of at admission — fine for this setup.
set -euo pipefail
# demo config — 00-rbac-kubeconfig.sh writes pre-setup/demo.env from the domain you enter
_ENV="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/pre-setup/demo.env"; [ -f "$_ENV" ] && . "$_ENV"
DEMO_DOMAIN="${DEMO_DOMAIN:-hobbyez.com}"

helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  -n ingress-nginx --create-namespace \
  --set controller.replicaCount=2 \
  --set controller.admissionWebhooks.enabled=false \
  --set controller.service.type=LoadBalancer \
  --set controller.service.externalTrafficPolicy=Cluster \
  --set 'controller.service.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-type=external' \
  --set 'controller.service.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-nlb-target-type=instance' \
  --set 'controller.service.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-scheme=internet-facing'

kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller

echo "NLB DNS (point Route53 ingress.* records here):"
kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{"\n"}'
