#!/usr/bin/env bash
# cert-manager — the in-cluster certificate controller (a cluster platform, install once). It
# watches Ingress/Certificate resources and obtains + renews TLS certs from an issuer. This is
# standard infra in real companies, which is why it lives in pre-setup.
#
# Setup 1 (ingress-nginx) uses it with a Let's Encrypt ClusterIssuer. Setups 2 & 3 terminate TLS
# at the AWS NLB with ACM instead, so they do NOT need cert-manager.
#
# Installs the platform via Helm (jetstack chart). If AWS keys are exported, it also creates the
# route53-creds Secret that the Let's Encrypt DNS-01 solver uses:
#   [AWS_ACCESS_KEY_ID=.. AWS_SECRET_ACCESS_KEY=..]  ./pre-setup/install-cert-manager.sh
set -euo pipefail

echo "── installing cert-manager (helm chart, jetstack) ──"
helm -n cert-manager status cert-manager >/dev/null 2>&1 || \
  helm install cert-manager cert-manager --repo https://charts.jetstack.io \
    -n cert-manager --create-namespace --set crds.enabled=true --wait

# credentials for the Let's Encrypt DNS-01 challenge (Route53) — only if AWS keys are provided
if [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]; then
  echo "── creating route53-creds (Let's Encrypt DNS-01) ──"
  kubectl -n cert-manager create secret generic route53-creds \
    --from-literal=access-key-id="$AWS_ACCESS_KEY_ID" \
    --from-literal=secret-access-key="$AWS_SECRET_ACCESS_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

cat <<'EOF'

cert-manager is up (namespace: cert-manager).
Next, apply an issuer so it can obtain certs. Setup 1 uses Let's Encrypt:
  kubectl apply -f cert-manager/clusterissuer.yaml     # ClusterIssuer: letsencrypt-prod
EOF
