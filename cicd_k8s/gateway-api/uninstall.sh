#!/usr/bin/env bash
# Tear down SETUP 2 (gateway-api / Envoy Gateway) so you can re-run the demo for the next batch.
#
# Removes:  frontend + backend apps + their namespaces, the HTTPRoutes + Gateway (which drops the
#           NLB), the Envoy Gateway controller + its GatewayClass/EnvoyProxy, AND the Gateway API +
#           Envoy Gateway CRDs — a fully clean teardown (kubectl get ns/crd shows nothing left).
# KEEPS:    the shared database and pre-setup (cluster infra).
#
# Uses your current admin context. Set DELETE_DNS=1 (with AWS creds) to also remove the
# gateway-api.* Route53 records (the NLB they point at is deleted here).
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

step "1 · removing Setup 2 apps + routes"
kubectl delete -f httproute.yaml --ignore-not-found
helm uninstall frontend -n gateway-frontend >/dev/null 2>&1 || true
del_ns gateway-frontend gateway-backend

step "2 · removing the Gateway (its finalizer drops the envoy Service + NLB)"
kubectl delete -f gateway.yaml --ignore-not-found        # acadcart-gateway in default

step "3 · removing the Envoy Gateway controller + all Gateway API CRDs"
kubectl delete gatewayclass eg --ignore-not-found
kubectl delete envoyproxy acm-proxy -n envoy-gateway-system --ignore-not-found
helm uninstall eg -n envoy-gateway-system >/dev/null 2>&1 || true
del_ns envoy-gateway-system

# helm uninstall never removes CRDs — drop them so the cluster is clean. Every CRD in the Gateway
# API group + Envoy Gateway's own group (whatever standard-install.yaml / the chart added). Safe:
# only Setup 2 uses these — Setup 3 (istio) uses networking.istio.io, not gateway.networking.k8s.io.
crds=$(kubectl get crd -o name 2>/dev/null \
        | grep -E '\.gateway\.networking\.k8s\.io$|\.gateway\.envoyproxy\.io$' || true)
if [ -n "$crds" ]; then
  for crd in $crds; do
    kubectl delete "$crd" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    echo "  removed CRD ${crd#*/}"
  done
else
  echo "  (no Gateway API CRDs present)"
fi

if [ "${DELETE_DNS:-0}" = "1" ]; then
  step "4 · removing Route53 records"
  ZONE="${HOSTED_ZONE_ID:-Z07010022C4LQ7Z9ZKUKL}"
  for name in "gateway-api.${DEMO_DOMAIN}" "gateway-api.backend.${DEMO_DOMAIN}"; do
    rr=$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE" \
          --query "ResourceRecordSets[?Name=='${name}.']|[0]" --output json 2>/dev/null || echo null)
    [ "$rr" = null ] && { echo "  ${name}: none"; continue; }
    batch=$(printf '{"Changes":[{"Action":"DELETE","ResourceRecordSet":%s}]}' "$rr")
    aws route53 change-resource-record-sets --hosted-zone-id "$ZONE" --change-batch "$batch" >/dev/null \
      && echo "  ${name}: deleted"
  done
fi

cat <<'EOF'

Setup 2 removed (incl. all CRDs). Still present: database, pre-setup.
Next batch — re-run the full setup (steps 1–12; build the image via CI = step 8):
  ./install.sh
EOF
