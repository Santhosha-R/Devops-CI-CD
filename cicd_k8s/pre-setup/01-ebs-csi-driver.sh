#!/usr/bin/env bash
# AWS EBS CSI driver (kubernetes-sigs) — gives the database StatefulSet real
# persistent disks. Without it a PVC stays Pending forever.
# Auth: reads AWS keys from secret/aws-secret in kube-system (created by ./00-rbac-kubeconfig.sh),
# NOT node IAM. Prereq: that Secret must exist.
set -euo pipefail
cd "$(dirname "$0")"

SECRET_NS=kube-system
AWS_SECRET=aws-secret

# 00 set local-admin as current in ~/.kube/config. But if your shell still exports KUBECONFIG
# pointing at a scoped kubeconfig (e.g. the deployer file), it masks that. If we are not admin
# now but ~/.kube/config is, drop the exported KUBECONFIG for this run.
if [ -n "${KUBECONFIG:-}" ] \
   && ! kubectl auth can-i create clusterroles >/dev/null 2>&1 \
   && env -u KUBECONFIG kubectl auth can-i create clusterroles >/dev/null 2>&1; then
  echo "note: exported KUBECONFIG=${KUBECONFIG} is not admin — using ~/.kube/config (local-admin)"
  unset KUBECONFIG
fi

# The helm chart creates ClusterRoles, a CSIDriver and a StorageClass — all cluster-scoped,
# none of which the deployer SA may create. Gate on `create clusterroles` (the real admin
# test); gating on `create deployment` would pass for the deployer and then fail mid-helm.
if ! kubectl auth can-i create clusterroles >/dev/null 2>&1; then
  echo "ERROR: this identity is not cluster-admin — installing the driver needs it."
  echo "  context: $(kubectl config current-context 2>/dev/null || echo none)"
  echo
  echo "  Run ./00-rbac-kubeconfig.sh first — it sets local-admin as your current context."
  echo "  Or switch to it:  kubectl config use-context local-admin@k8s-3tier"
  exit 1
fi

CHART_VERSION="${CHART_VERSION:-2.62.0}"   # helm search repo aws-ebs-csi-driver --versions

# The driver authenticates with the static keys in secret/aws-secret. Fail early if missing.
if ! kubectl -n "$SECRET_NS" get secret "$AWS_SECRET" >/dev/null 2>&1; then
  echo "ERROR: secret/${AWS_SECRET} not found in ${SECRET_NS}. Run ./00-rbac-kubeconfig.sh first"
  echo "       (with AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY exported)."
  exit 1
fi

helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver >/dev/null 2>&1 || true
helm repo update >/dev/null

# awsAccessSecret.* points the driver at our Secret's keys (the chart default names are
# key_id/access_key; ours are the standard AWS_ env names, so we override them here).
helm upgrade --install aws-ebs-csi-driver \
  aws-ebs-csi-driver/aws-ebs-csi-driver \
  --version "$CHART_VERSION" \
  -n kube-system \
  --set controller.replicaCount=2 \
  --set awsAccessSecret.name="$AWS_SECRET" \
  --set awsAccessSecret.keyId=AWS_ACCESS_KEY_ID \
  --set awsAccessSecret.accessKey=AWS_SECRET_ACCESS_KEY

kubectl -n kube-system rollout status deploy/ebs-csi-controller
kubectl apply -f storageclass.yaml

echo
kubectl get csidrivers ebs.csi.aws.com
kubectl get storageclass
