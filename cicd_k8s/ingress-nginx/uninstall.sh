#!/usr/bin/env bash
# Tear down SETUP 1 (ingress-nginx) so you can re-run the demo for the next batch.
#
# Removes:  frontend + backend apps, their Ingresses + TLS certs, the app namespaces, the
#           ingress-nginx controller + its NLB, and its cluster-scoped IngressClass + admission
#           webhook (no CRDs — nginx uses the built-in Ingress). A fully clean teardown.
# KEEPS:    the shared database, cert-manager, and everything in pre-setup (cluster infra) —
#           those are batch-independent, so leave them and just re-run install + deploy.
#
# Uses your current admin context. Set DELETE_DNS=1 (with AWS_* creds) to also remove the
# Route53 records, since the NLB they point at is deleted here.
set -euo pipefail
# demo config — 00-rbac-kubeconfig.sh writes pre-setup/demo.env from the domain you enter
_ENV="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/pre-setup/demo.env"; [ -f "$_ENV" ] && . "$_ENV"
DEMO_DOMAIN="${DEMO_DOMAIN:-hobbyez.com}"
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

step "1 · removing Setup 1 apps + ingresses"
# ingresses first (frees the cert-manager Certificates / LE order), then the helm release,
# then the namespaces (which sweep up deployments, services, secrets, and any leftovers).
kubectl delete ingress frontend -n ingress-frontend --ignore-not-found
kubectl delete ingress backend  -n ingress-backend  --ignore-not-found
helm uninstall backend -n ingress-backend >/dev/null 2>&1 || true
del_ns ingress-frontend ingress-backend

step "2 · removing the ingress-nginx controller + its NLB, IngressClass & webhook"
# helm uninstall deletes the type=LoadBalancer Service, which makes the AWS LB controller
# delete the NLB. Do it before dropping the namespace so the finalizer runs.
helm uninstall ingress-nginx -n ingress-nginx >/dev/null 2>&1 || true
del_ns ingress-nginx
# helm uninstall already removes these cluster-scoped bits; sweep them explicitly so
# `kubectl get ingressclass,validatingwebhookconfiguration` is guaranteed clean.
kubectl delete ingressclass nginx --ignore-not-found
kubectl delete validatingwebhookconfiguration ingress-nginx-admission --ignore-not-found

if [ "${DELETE_DNS:-0}" = "1" ]; then
  step "3 · removing Route53 records (they point at the now-deleted NLB)"
  ZONE="${HOSTED_ZONE_ID:-Z07010022C4LQ7Z9ZKUKL}"
  for name in "ingress.${DEMO_DOMAIN}" "ingress.backend.${DEMO_DOMAIN}"; do
    rr=$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE" \
          --query "ResourceRecordSets[?Name=='${name}.']|[0]" --output json 2>/dev/null || echo null)
    [ "$rr" = null ] && { echo "  ${name}: none"; continue; }
    batch=$(printf '{"Changes":[{"Action":"DELETE","ResourceRecordSet":%s}]}' "$rr")
    aws route53 change-resource-record-sets --hosted-zone-id "$ZONE" --change-batch "$batch" >/dev/null \
      && echo "  ${name}: deleted"
  done
fi

cat <<EOF

Setup 1 removed (controller, IngressClass, webhook). Still present: database, cert-manager, pre-setup.

Next batch — re-run the full setup (steps 1–12; build the image via CI = step 8):
  ./install.sh
EOF
