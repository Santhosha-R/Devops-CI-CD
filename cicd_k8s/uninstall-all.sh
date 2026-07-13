#!/usr/bin/env bash
# Batch reset — remove ALL THREE setups (apps, routing, gateways/controllers, and their NLBs),
# keeping ONLY the shared database and pre-setup (cluster infra) so the next batch reuses them.
#
# Runs each setup's own uninstall.sh. Pass DELETE_DNS=1 (with AWS creds) to also drop the
# per-setup Route53 records. One setup failing does not stop the others.
set -uo pipefail
# demo config — 00-rbac-kubeconfig.sh writes pre-setup/demo.env from the domain you enter
_ENV="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/pre-setup/demo.env"; [ -f "$_ENV" ] && . "$_ENV"
DEMO_DOMAIN="${DEMO_DOMAIN:-hobbyez.com}"
cd "$(dirname "$0")"

for s in ingress-nginx gateway-api istio; do
  echo
  echo "════════════════ tearing down: $s ════════════════"
  ( ./"$s"/uninstall.sh ) || echo "  ($s uninstall reported errors — continuing)"
done

cat <<EOF

════════════════════════════════════════════════════════
All three setups removed. Kept: database, pre-setup (EBS, LB controller, RBAC, cert-manager).

Next batch — reinstall each setup:
  ingress-nginx:  ./ingress-nginx/install.sh
  gateway-api:    ./gateway-api/install.sh
  istio:          ./istio/install.sh
then redeploy apps, re-point the *.${DEMO_DOMAIN} DNS records at the new NLBs, and apply the routing.
════════════════════════════════════════════════════════
EOF
