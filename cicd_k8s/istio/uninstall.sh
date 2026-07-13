#!/usr/bin/env bash
# Tear down SETUP 3 (istio) so you can re-run the demo for the next batch.
#
# Removes:  the ArgoCD Applications (so they stop re-syncing the apps back), frontend + backend
#           apps + their namespaces, the Gateway + VirtualServices, the istio ingress gateway
#           + istiod + base (removing the ingress gateway Service drops the NLB), AND all istio
#           CRDs — a fully clean teardown (kubectl get ns/crd shows nothing left).
# KEEPS:    the shared database and pre-setup (cluster infra).
#
# Uses your current admin context. Set DELETE_DNS=1 (with AWS creds) to also remove the
# istio.* Route53 records (the NLB they point at is deleted here).
set -euo pipefail
# demo config — 00-rbac-kubeconfig.sh writes pre-setup/demo.env from the domain you enter
_ENV="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/pre-setup/demo.env"; [ -f "$_ENV" ] && . "$_ENV"
DEMO_DOMAIN="${DEMO_DOMAIN:-hobbyez.com}"
cd "$(dirname "$0")"
step(){ printf '\n\033[1;34m━━ %s ━━\033[0m\n' "$1"; }

# del_ns <ns...> — delete namespaces, wait for them to actually terminate, and force-remove any
# left stuck in Terminating (a leftover finalizer) past NS_WAIT seconds (default 120).
del_ns(){
  local wait_s="${NS_WAIT:-120}" ns left deadline
  kubectl delete namespace "$@" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  deadline=$((SECONDS + wait_s))
  while :; do
    left=""
    for ns in "$@"; do
      if kubectl get namespace "$ns" >/dev/null 2>&1; then left="$left $ns"; fi
    done
    [ -z "$left" ] && { echo "  namespaces removed:$*"; return 0; }
    [ "$SECONDS" -ge "$deadline" ] && break
    echo "  waiting for termination …$left"
    sleep 5
  done
  for ns in $left; do
    echo "  ⚠ $ns still Terminating after ${wait_s}s — force-removing (clearing finalizers)"
    printf '{"kind":"Namespace","apiVersion":"v1","metadata":{"name":"%s"},"spec":{"finalizers":[]}}' "$ns" \
      | kubectl replace --raw "/api/v1/namespaces/${ns}/finalize" -f - >/dev/null 2>&1 \
      && echo "    forced: $ns gone" || echo "    could not force $ns — check: kubectl get ns $ns -o yaml"
  done
}

step "1 · stopping ArgoCD sync (delete the Applications first, else they recreate the apps)"
kubectl delete -f argocd/applications.yaml --ignore-not-found 2>/dev/null || true

step "2 · removing Setup 3 apps + routing"
kubectl delete -f virtualservice.yaml -f gateway.yaml --ignore-not-found
helm uninstall frontend -n istio-frontend >/dev/null 2>&1 || true          # if deployed via helm manually
del_ns istio-frontend istio-backend

step "3 · removing the istio ingress gateway (drops its NLB) + control plane + CRDs"
helm uninstall istio-ingressgateway -n istio-ingress >/dev/null 2>&1 || true
del_ns istio-ingress
helm uninstall istiod     -n istio-system >/dev/null 2>&1 || true
helm uninstall istio-base -n istio-system >/dev/null 2>&1 || true
del_ns istio-system

# istio-base installs the CRDs and helm uninstall never removes CRDs — drop every istio.io CRD
# (networking / security / telemetry / extensions / install) so the cluster is clean.
crds=$(kubectl get crd -o name 2>/dev/null | grep -E '\.istio\.io$' || true)
if [ -n "$crds" ]; then
  for crd in $crds; do
    kubectl delete "$crd" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    echo "  removed CRD ${crd#*/}"
  done
else
  echo "  (no istio CRDs present)"
fi

if [ "${DELETE_DNS:-0}" = "1" ]; then
  step "4 · removing Route53 records"
  ZONE="${HOSTED_ZONE_ID:-Z07010022C4LQ7Z9ZKUKL}"
  for name in "istio.${DEMO_DOMAIN}" "istio.backend.${DEMO_DOMAIN}"; do
    rr=$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE" \
          --query "ResourceRecordSets[?Name=='${name}.']|[0]" --output json 2>/dev/null || echo null)
    [ "$rr" = null ] && { echo "  ${name}: none"; continue; }
    batch=$(printf '{"Changes":[{"Action":"DELETE","ResourceRecordSet":%s}]}' "$rr")
    aws route53 change-resource-record-sets --hosted-zone-id "$ZONE" --change-batch "$batch" >/dev/null \
      && echo "  ${name}: deleted"
  done
fi

cat <<'EOF'

Setup 3 removed (incl. all istio CRDs). Still present: database, pre-setup.
Next batch — re-run the full setup (steps 1–12; build the image via CI = step 8):
  ./install.sh
EOF
