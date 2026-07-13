#!/usr/bin/env bash
# Tear down the shared MongoDB. This is NOT part of a batch reset — the per-setup
# uninstalls keep the database up. Run this only when you are completely done.
#
# The PVC uses ebs-sc (reclaimPolicy: Retain), so deleting the Kubernetes resources
# LEAVES the EBS volume in AWS — your data survives. Set DELETE_DATA=1 (with AWS creds)
# to also delete the underlying EBS volume. That is irreversible.
set -euo pipefail
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

# resolve the backing EBS volume id before we delete anything
PV=$(kubectl -n database get pvc mongo-data-mongo-0 -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)
VOL=""
[ -n "$PV" ] && VOL=$(kubectl get pv "$PV" -o jsonpath='{.spec.csi.volumeHandle}' 2>/dev/null || true)

step "1 · removing MongoDB (statefulset, pods, service, secret, PVC, namespace)"
del_ns database    # PV is Retain, so the EBS volume survives even if we force-remove the namespace

if [ -z "${VOL:-}" ]; then
  echo "No EBS volume found to report (already gone?)."
  exit 0
fi

echo
echo "Retained EBS volume (data preserved): $VOL"
if [ "${DELETE_DATA:-0}" != "1" ]; then
  echo "Keep it, or delete later with:"
  echo "  aws ec2 delete-volume --volume-id $VOL --region ${AWS_REGION:-ap-south-1}"
  exit 0
fi

echo "DELETE_DATA=1 → deleting the released PV + EBS volume (irreversible)…"
[ -n "$PV" ] && kubectl delete pv "$PV" --ignore-not-found --wait=false
# the volume detaches when the pod dies; wait for 'available' before deleting it
for i in $(seq 1 20); do
  state=$(aws ec2 describe-volumes --volume-ids "$VOL" --region "${AWS_REGION:-ap-south-1}" \
            --query 'Volumes[0].State' --output text 2>/dev/null || echo missing)
  [ "$state" = missing ] && { echo "  volume already gone"; exit 0; }
  [ "$state" = available ] && break
  echo "  volume state=$state … waiting"; sleep 6
done
aws ec2 delete-volume --volume-id "$VOL" --region "${AWS_REGION:-ap-south-1}" \
  && echo "  deleted $VOL"
