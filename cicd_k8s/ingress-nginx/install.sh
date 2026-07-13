#!/usr/bin/env bash
# Setup 1 — FULL setup. Runs the install.md steps 1 → 12 end to end (everything automatable).
#
# The ONE manual step is 8 (CI build & push the image to ECR) — trigger your Jenkins pipeline, or
# build once by hand. This script deploys image tag :${IMAGE_TAG} (default 1); until that tag
# exists in ECR the app pods sit in ImagePullBackOff, then recover on their own.
#
# Prereqs: pre-setup step 1 (./pre-setup/00-rbac-kubeconfig.sh) done once, and AWS creds exported:
#   export AWS_ACCESS_KEY_ID=...  AWS_SECRET_ACCESS_KEY=...  AWS_REGION=ap-south-1
#   ./ingress-nginx/install.sh
set -euo pipefail
# demo config — 00-rbac-kubeconfig.sh writes pre-setup/demo.env from the domain you enter
_ENV="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/pre-setup/demo.env"; [ -f "$_ENV" ] && . "$_ENV"
DEMO_DOMAIN="${DEMO_DOMAIN:-hobbyez.com}"
cd "$(dirname "$0")/.."                                   # -> cicd_k8s/

: "${AWS_ACCESS_KEY_ID:?export AWS_ACCESS_KEY_ID}"
: "${AWS_SECRET_ACCESS_KEY:?export AWS_SECRET_ACCESS_KEY}"
export AWS_REGION="${AWS_REGION:-ap-south-1}" AWS_PAGER=""
IMAGE_TAG="${IMAGE_TAG:-1}"
ZONE="${HOSTED_ZONE_ID:-Z07010022C4LQ7Z9ZKUKL}"
REGISTRY="637423622313.dkr.ecr.${AWS_REGION}.amazonaws.com"
step(){ printf '\n\033[1;34m━━ %s ━━\033[0m\n' "$1"; }
kapply(){ local f z="${HOSTED_ZONE_ID:-Z07010022C4LQ7Z9ZKUKL}" r="${AWS_REGION:-ap-south-1}"
  for f in "$@"; do sed -e "s/hobbyez\.com/${DEMO_DOMAIN}/g" -e "s/Z07010022C4LQ7Z9ZKUKL/${z}/g" -e "s/ap-south-1/${r}/g" "$f"; printf '\n---\n'; done | kubectl apply -f -; }
pull_secret(){                                            # $1 = namespace
  kubectl create namespace "$1" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "$1" create secret docker-registry ecr-creds --docker-server="$REGISTRY" \
    --docker-username=AWS --docker-password="$(aws ecr get-login-password --region "$AWS_REGION")" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null; }
dns(){                                                    # $1 = host  $2 = NLB hostname
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

step "5 · cert-manager + Let's Encrypt issuer"
./pre-setup/03-install-cert-manager.sh                  # platform + route53-creds (uses exported AWS keys)
kapply cert-manager/clusterissuer.yaml               # ClusterIssuer: letsencrypt-prod

step "6 · shared database (MongoDB)"
./database/apply.sh

step "7 · ingress-nginx controller"
./ingress-nginx/install-controller.sh

step "8 · CI build — MANUAL: build & push ${REGISTRY}/{frontend_react,backend_node}:${IMAGE_TAG}"

step "9 · deploy apps (frontend YAML, backend Helm)"
pull_secret ingress-frontend
kapply ingress-nginx/frontend/*.yaml
kubectl -n ingress-frontend set image deployment/frontend frontend="${REGISTRY}/frontend_react:${IMAGE_TAG}"
pull_secret ingress-backend
helm upgrade --install backend ingress-nginx/backend -n ingress-backend --create-namespace \
  -f <(sed "s/hobbyez\.com/${DEMO_DOMAIN}/g" ingress-nginx/backend/values.yaml) --set image.tag="$IMAGE_TAG"

step "10 · routing (ingress + Let's Encrypt TLS)"
kapply ingress-nginx/ingress.yaml

step "11 · Route53 records → NLB"
echo "  waiting for the NLB hostname…"
NLB=""; for i in $(seq 1 40); do
  NLB=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [ -n "$NLB" ] && break; sleep 6; done
[ -z "$NLB" ] && { echo "  NLB not ready — re-run once it is."; exit 1; }
dns "ingress.${DEMO_DOMAIN}" "$NLB"
dns "ingress.backend.${DEMO_DOMAIN}" "$NLB"

step "12 · verify"
sleep 5
verify "https://ingress.${DEMO_DOMAIN}" "ingress.${DEMO_DOMAIN}"
verify "https://ingress.backend.${DEMO_DOMAIN}/healthz" "ingress.backend.${DEMO_DOMAIN}"
echo "  (expect 200 once the ECR image exists + the LE cert is issued, ~1–2 min)"
