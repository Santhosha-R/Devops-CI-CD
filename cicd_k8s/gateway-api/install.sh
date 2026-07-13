#!/usr/bin/env bash
# Setup 2 — FULL setup. Runs the install.md steps 1 → 12 end to end (everything automatable).
#
# The ONE manual step is 8 (CI build & push the image to ECR) — trigger your GitHub Actions
# workflow, or build once by hand. This script deploys image tag :${IMAGE_TAG} (default 1).
#
# Prereqs: pre-setup step 1 (./pre-setup/00-rbac-kubeconfig.sh) done once, and AWS creds:
#   export AWS_ACCESS_KEY_ID=...  AWS_SECRET_ACCESS_KEY=...  AWS_REGION=ap-south-1
#   ./gateway-api/install.sh
# The ACM cert is AUTO-RESOLVED (reuses the *.hobbyez.com cert, else creates + DNS-validates it).
# Pin a specific one with: ACM_ARN=<arn> ./gateway-api/install.sh
set -euo pipefail
# demo config — 00-rbac-kubeconfig.sh writes pre-setup/demo.env from the domain you enter
_ENV="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/pre-setup/demo.env"; [ -f "$_ENV" ] && . "$_ENV"
DEMO_DOMAIN="${DEMO_DOMAIN:-hobbyez.com}"
cd "$(dirname "$0")/.."                                   # -> cicd_k8s/

: "${AWS_ACCESS_KEY_ID:?export AWS_ACCESS_KEY_ID}"
: "${AWS_SECRET_ACCESS_KEY:?export AWS_SECRET_ACCESS_KEY}"
export AWS_REGION="${AWS_REGION:-ap-south-1}" AWS_PAGER=""
ACM_DOMAIN="${ACM_DOMAIN:-*.${DEMO_DOMAIN}}"             # ACM_ARN is auto-resolved from this (or pass ACM_ARN=)
IMAGE_TAG="${IMAGE_TAG:-1}"
ZONE="${HOSTED_ZONE_ID:-Z07010022C4LQ7Z9ZKUKL}"
REGISTRY="637423622313.dkr.ecr.${AWS_REGION}.amazonaws.com"
step(){ printf '\n\033[1;34m━━ %s ━━\033[0m\n' "$1"; }
kapply(){ local f z="${HOSTED_ZONE_ID:-Z07010022C4LQ7Z9ZKUKL}" r="${AWS_REGION:-ap-south-1}"
  for f in "$@"; do sed -e "s/hobbyez\.com/${DEMO_DOMAIN}/g" -e "s/Z07010022C4LQ7Z9ZKUKL/${z}/g" -e "s/ap-south-1/${r}/g" "$f"; printf '\n---\n'; done | kubectl apply -f -; }
acm_lookup(){ aws acm list-certificates --region "$AWS_REGION" --certificate-statuses ISSUED \
  --query "CertificateSummaryList[?DomainName=='${ACM_DOMAIN}'].CertificateArn | [0]" --output text 2>/dev/null || true; }
pull_secret(){
  kubectl create namespace "$1" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "$1" create secret docker-registry ecr-creds --docker-server="$REGISTRY" \
    --docker-username=AWS --docker-password="$(aws ecr get-login-password --region "$AWS_REGION")" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null; }
dns(){
  aws route53 change-resource-record-sets --hosted-zone-id "$ZONE" --change-batch \
    "{\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"$1\",\"Type\":\"CNAME\",\"TTL\":60,\"ResourceRecords\":[{\"Value\":\"$2\"}]}}]}" >/dev/null && echo "  $1 -> $2"; }
verify(){                                                 # $1 = url  $2 = host
  # A brand-new NLB's DNS + target health take ~1-3 min. Retry, connecting straight to the NLB with
  # the record's SNI/Host (portable — curl only, no dig). Breaks as soon as it returns 200.
  local code=000 a
  for a in $(seq 1 15); do
    code=$(curl -sS -m 8 --connect-to "${2}:443:${NLB}:443" -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || echo 000)
    [ "$code" = 200 ] && break
    sleep 8
  done
  echo "  $1 -> $code"
  [ "$code" = 200 ] || echo "     (not 200 yet — new NLB DNS/targets take a few min, or build the image in step 8)"; }

step "1 · admin access (pre-setup bootstrap, once per cluster)"
kubectl auth can-i create clusterrole >/dev/null 2>&1 \
  || { echo "Not cluster-admin. Run ./pre-setup/00-rbac-kubeconfig.sh first."; exit 1; }

step "2 · EBS CSI driver"
helm -n kube-system status aws-ebs-csi-driver >/dev/null 2>&1 || ./pre-setup/01-ebs-csi-driver.sh
kubectl apply -f pre-setup/storageclass.yaml

step "3 · AWS Load Balancer Controller"
helm -n kube-system status aws-load-balancer-controller >/dev/null 2>&1 || ./pre-setup/02-aws-load-balancer-controller.sh

step "4 · ECR repositories"
./pre-setup/05-ecr-setup.sh

step "5 · ACM certificate (auto-resolved — TLS terminates at the NLB)"
# no need to pass ACM_ARN: reuse the ISSUED *.hobbyez.com cert if it exists, else create +
# DNS-validate it via pre-setup/06 (idempotent), then look it up. Override with ACM_ARN=<arn>.
if [ -z "${ACM_ARN:-}" ]; then
  ACM_ARN=$(acm_lookup)
  if [ -z "$ACM_ARN" ] || [ "$ACM_ARN" = None ]; then
    echo "  no ISSUED ${ACM_DOMAIN} cert yet — creating + validating it (pre-setup/06)…"
    ./pre-setup/06-acm-cert.sh
    ACM_ARN=$(acm_lookup)
  fi
  echo "  auto-resolved ACM_ARN=$ACM_ARN"
fi
export ACM_ARN
if aws acm describe-certificate --certificate-arn "${ACM_ARN:-none}" \
     --query 'Certificate.Status' --output text 2>/dev/null | grep -q ISSUED; then
  echo "  ACM cert ISSUED ✓  $ACM_ARN"
else
  echo "  no ISSUED ACM cert — run ./pre-setup/06-acm-cert.sh (or pass ACM_ARN=<arn>)."; exit 1
fi

step "6 · shared database (MongoDB)"
./database/apply.sh

step "7 · Envoy Gateway controller"
./gateway-api/install-controller.sh

step "8 · CI build — MANUAL: build & push ${REGISTRY}/{frontend_react,backend_node}:${IMAGE_TAG}"

step "9 · deploy apps (frontend Helm, backend YAML)"
pull_secret gateway-frontend
helm upgrade --install frontend gateway-api/frontend -n gateway-frontend --create-namespace \
  -f <(sed "s/hobbyez\.com/${DEMO_DOMAIN}/g" gateway-api/frontend/values.yaml) --set image.tag="$IMAGE_TAG"
pull_secret gateway-backend
kapply gateway-api/backend/*.yaml
kubectl -n gateway-backend set image deployment/backend backend="${REGISTRY}/backend_node:${IMAGE_TAG}"

step "10 · routing (Gateway + HTTPRoute) — this provisions the NLB"
kapply gateway-api/gateway.yaml gateway-api/httproute.yaml

step "11 · Route53 records → NLB"
echo "  waiting for the Envoy NLB hostname…"
NLB=""; for i in $(seq 1 40); do
  NLB=$(kubectl -n envoy-gateway-system get svc -l gateway.envoyproxy.io/owning-gateway-name=acadcart-gateway \
        -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [ -n "$NLB" ] && break; sleep 6; done
[ -z "$NLB" ] && { echo "  NLB not ready — re-run once it is."; exit 1; }
dns "gateway-api.${DEMO_DOMAIN}" "$NLB"
dns "gateway-api.backend.${DEMO_DOMAIN}" "$NLB"

step "12 · verify"
sleep 5
verify "https://gateway-api.${DEMO_DOMAIN}" "gateway-api.${DEMO_DOMAIN}"
verify "https://gateway-api.backend.${DEMO_DOMAIN}/healthz" "gateway-api.backend.${DEMO_DOMAIN}"
echo "  (expect 200 once the ECR image exists + DNS propagates)"
