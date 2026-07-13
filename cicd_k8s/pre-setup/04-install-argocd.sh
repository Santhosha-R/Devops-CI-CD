#!/usr/bin/env bash
# ArgoCD — the GitOps CD platform (cluster infra, install once). Setup 3 (istio) uses it to sync
# its apps, but it is cluster-wide and can serve any setup. Installed via Helm (chart argo-cd).
# Keep it across batches; the per-setup uninstalls only remove the Apps.
#
# ACCESS is AUTOMATIC — no flags needed:
#   • With working AWS auth + an ISSUED *.hobbyez.com ACM cert in reach, ArgoCD is exposed at a FIXED
#     HTTPS URL behind an internet-facing NLB (TLS terminates at the NLB with ACM; argocd-server runs
#     --insecure — same model as Setups 2 & 3) and a Route53 record is created + updated automatically.
#     Default host: argocd.hobbyez.com  (override ARGOCD_HOST=..., or ARGOCD_HOST="" for port-forward).
#   • Without AWS creds / cert → falls back to ClusterIP + `kubectl port-forward`.
#
# Optional:
#   ARGOCD_SOURCE_RANGES="1.2.3.4/32,5.6.0.0/16"   restrict who can reach the NLB (recommended)
#   GITHUB_USER=.. GITHUB_PAT=..                    register the (private) cicd_k8s repo for Argo to read
set -euo pipefail
# demo config — 00-rbac-kubeconfig.sh writes pre-setup/demo.env from the domain you enter
_ENV="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/pre-setup/demo.env"; [ -f "$_ENV" ] && . "$_ENV"
DEMO_DOMAIN="${DEMO_DOMAIN:-hobbyez.com}"
cd "$(dirname "$0")/.."

REPO_URL="${REPO_URL:-https://github.com/itdefined-org-apps/cicd_k8s.git}"
VER="${ARGOCD_CHART_VERSION:-10.1.3}"                     # matches the live install (app v3.4.5)
ARGOCD_HOST="${ARGOCD_HOST:-argocd.${DEMO_DOMAIN}}"          # fixed URL by default; set to "" for port-forward only
ZONE="${HOSTED_ZONE_ID:-Z07010022C4LQ7Z9ZKUKL}"
ACM_DOMAIN="${ACM_DOMAIN:-*.${DEMO_DOMAIN}}"
export AWS_PAGER=""
step(){ printf '\n\033[1;34m━━ %s ━━\033[0m\n' "$1"; }

# ---- decide whether we can expose behind an NLB (needs working AWS auth + an ISSUED ACM cert) ----
EXPOSE=0
if [ -n "$ARGOCD_HOST" ]; then
  export AWS_REGION="${AWS_REGION:-ap-south-1}"
  if aws sts get-caller-identity >/dev/null 2>&1; then
    if [ -z "${ACM_ARN:-}" ]; then
      ACM_ARN=$(aws acm list-certificates --region "$AWS_REGION" --certificate-statuses ISSUED \
        --query "CertificateSummaryList[?DomainName=='${ACM_DOMAIN}'].CertificateArn | [0]" --output text 2>/dev/null || true)
    fi
    if [ -n "${ACM_ARN:-}" ] && [ "$ACM_ARN" != None ]; then
      EXPOSE=1
    else
      echo "note: no ISSUED ${ACM_DOMAIN} ACM cert found — installing ClusterIP (use port-forward)."
      echo "      run ./pre-setup/06-acm-cert.sh, then re-run this to expose at https://${ARGOCD_HOST}."
    fi
  else
    echo "note: no working AWS auth in this shell — installing ClusterIP (use port-forward)."
    echo "      export AWS creds + re-run this to auto-expose at https://${ARGOCD_HOST}."
  fi
fi

step "1 · install ArgoCD (helm chart argo-cd ${VER})"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null

if [ "$EXPOSE" = 1 ]; then
  echo "  exposing at https://${ARGOCD_HOST}  (NLB terminates ACM TLS ${ACM_ARN} -> argocd-server :8080)"
  A='server.service.annotations.service\.beta\.kubernetes\.io/aws-load-balancer'   # annotation key prefix
  helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace --version "$VER" --wait \
    --set-string 'configs.params.server\.insecure=true' \
    --set-string "configs.cm.url=https://${ARGOCD_HOST}" \
    --set        'server.service.type=LoadBalancer' \
    --set-string "${A}-type=external" \
    --set-string "${A}-nlb-target-type=instance" \
    --set-string "${A}-scheme=internet-facing" \
    --set-string "${A}-ssl-cert=${ACM_ARN}" \
    --set-string "${A}-ssl-ports=443"

  if [ -n "${ARGOCD_SOURCE_RANGES:-}" ]; then          # optional: lock the NLB to specific CIDRs
    arr=""; for c in ${ARGOCD_SOURCE_RANGES//,/ }; do arr="${arr:+$arr,}\"$c\""; done
    kubectl -n argocd patch svc argocd-server -p "{\"spec\":{\"loadBalancerSourceRanges\":[$arr]}}" >/dev/null
    echo "  access restricted to: ${ARGOCD_SOURCE_RANGES}"
  fi
else
  helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace --version "$VER" --wait
fi

# register the shared cicd_k8s repo as a credentialed source only if a PAT is supplied (private repo)
if [ -n "${GITHUB_PAT:-}" ]; then
  step "2 · register repo ${REPO_URL}"
  kubectl apply -f - <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: repo-cicd-k8s
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: ${REPO_URL}
  username: ${GITHUB_USER:-git}
  password: ${GITHUB_PAT}
YAML
fi

if [ "$EXPOSE" = 1 ]; then
  step "3 · Route53 ${ARGOCD_HOST} -> NLB (auto)"
  echo "  waiting for the ArgoCD NLB hostname…"
  NLB=""; for i in $(seq 1 40); do
    NLB=$(kubectl -n argocd get svc argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    [ -n "$NLB" ] && break; sleep 6
  done
  [ -z "$NLB" ] && { echo "  NLB not ready — re-run once it is."; exit 1; }
  aws route53 change-resource-record-sets --hosted-zone-id "$ZONE" --change-batch \
    "{\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"${ARGOCD_HOST}\",\"Type\":\"CNAME\",\"TTL\":60,\"ResourceRecords\":[{\"Value\":\"${NLB}\"}]}}]}" >/dev/null
  echo "  ${ARGOCD_HOST} -> ${NLB}"
fi

step "done"
if [ "$EXPOSE" = 1 ]; then
  cat <<EOF
ArgoCD is up at a FIXED URL — no port-forward:
  https://${ARGOCD_HOST}      (user admin;  a brand-new NLB's DNS can take 1-3 min)
  pw:  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
  CLI: argocd login ${ARGOCD_HOST} --grpc-web
Public on the internet — change the admin password on first login (and set ARGOCD_SOURCE_RANGES to lock it down).
EOF
else
  cat <<EOF
ArgoCD is up (namespace: argocd), ClusterIP.
UI:  kubectl -n argocd port-forward svc/argocd-server 8080:443   ->  https://localhost:8080  (user admin)
pw:  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
EOF
fi
cat <<EOF

Register a setup's apps — e.g. Setup 3 (istio):
  kubectl apply -f istio/argocd/applications.yaml   # push cicd_k8s first — Argo reads git, not local
EOF
