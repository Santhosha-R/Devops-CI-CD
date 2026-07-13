#!/usr/bin/env bash
# ACM wildcard certificate for the demo domains — used by Setup 2 (gateway-api) and Setup 3 (istio),
# which terminate TLS at the AWS NLB. (Setup 1 uses cert-manager + Let's Encrypt instead.)
# A one-time AWS prerequisite, hence pre-setup. Idempotent: reuses an existing *.hobbyez.com cert.
#
# Requests a DNS-validated cert for *.hobbyez.com (+ *.backend.hobbyez.com), auto-creates the
# Route53 validation records, waits for ISSUED, and prints the ARN to export.
#
#   export AWS_ACCESS_KEY_ID=..  AWS_SECRET_ACCESS_KEY=..  AWS_REGION=ap-south-1
#   ./pre-setup/06-acm-cert.sh
#   export ACM_ARN=<the arn it prints>
set -euo pipefail
# demo config — 00-rbac-kubeconfig.sh writes pre-setup/demo.env from the domain you enter
_ENV="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/pre-setup/demo.env"; [ -f "$_ENV" ] && . "$_ENV"
DEMO_DOMAIN="${DEMO_DOMAIN:-hobbyez.com}"
export AWS_PAGER=""
REGION="${AWS_REGION:-ap-south-1}"
ZONE="${HOSTED_ZONE_ID:-Z07010022C4LQ7Z9ZKUKL}"
DOMAIN="${ACM_DOMAIN:-*.${DEMO_DOMAIN}}"
SAN="${ACM_SAN:-*.backend.${DEMO_DOMAIN}}"
step(){ printf '\n\033[1;34m━━ %s ━━\033[0m\n' "$1"; }

step "1 · request (or reuse) the cert for ${DOMAIN} (+ ${SAN})"
ARN=$(aws acm list-certificates --region "$REGION" \
        --certificate-statuses ISSUED PENDING_VALIDATION \
        --query "CertificateSummaryList[?DomainName=='${DOMAIN}'].CertificateArn | [0]" --output text 2>/dev/null || echo None)
if [ -n "$ARN" ] && [ "$ARN" != None ]; then
  echo "  reusing existing cert: $ARN"
else
  ARN=$(aws acm request-certificate --region "$REGION" \
          --domain-name "$DOMAIN" --subject-alternative-names "$SAN" \
          --validation-method DNS --query CertificateArn --output text)
  echo "  requested new cert: $ARN"
fi

step "2 · create the DNS validation records in Route53"
# ACM populates the validation records a few seconds after request — wait for them to appear
for i in $(seq 1 20); do
  ready=$(aws acm describe-certificate --region "$REGION" --certificate-arn "$ARN" \
            --query 'length(Certificate.DomainValidationOptions[].ResourceRecord)' --output text 2>/dev/null || echo 0)
  [ "$ready" != 0 ] && [ "$ready" != None ] && break
  sleep 3
done
n=$(aws acm describe-certificate --region "$REGION" --certificate-arn "$ARN" \
      --query 'length(Certificate.DomainValidationOptions)' --output text)
idx=0
while [ "$idx" -lt "$n" ]; do
  read -r vname vtype vvalue <<< "$(aws acm describe-certificate --region "$REGION" --certificate-arn "$ARN" \
        --query "Certificate.DomainValidationOptions[$idx].ResourceRecord.[Name,Type,Value]" --output text 2>/dev/null || echo)"
  idx=$((idx+1))
  if [ -z "${vname:-}" ] || [ "$vname" = None ]; then continue; fi
  batch="{\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"$vname\",\"Type\":\"$vtype\",\"TTL\":300,\"ResourceRecords\":[{\"Value\":\"$vvalue\"}]}}]}"
  aws route53 change-resource-record-sets --hosted-zone-id "$ZONE" --change-batch "$batch" >/dev/null && echo "  ✓ $vname"
done

step "3 · wait for the cert to be ISSUED (DNS validation, ~2-5 min)"
aws acm wait certificate-validated --region "$REGION" --certificate-arn "$ARN" 2>/dev/null || true
status=$(aws acm describe-certificate --region "$REGION" --certificate-arn "$ARN" --query 'Certificate.Status' --output text)
echo "  status: $status"

cat <<EOF

Use this cert for Setup 2 (gateway-api) and Setup 3 (istio):
  export ACM_ARN=$ARN
EOF
[ "$status" = ISSUED ] || echo "(not ISSUED yet — validation can take a few minutes; re-run to re-check.)"
