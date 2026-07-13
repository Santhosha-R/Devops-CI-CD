#!/usr/bin/env bash
# AWS Load Balancer Controller (kubernetes-sigs) — makes Service type=LoadBalancer
# provision a real NLB. Required by ../ingress-nginx.
# Auth: reads AWS keys from secret/aws-secret in kube-system (created by ./00-rbac-kubeconfig.sh),
# injected as env vars after install — NOT node IAM.
# The AWS CLI here (subnet discovery + tagging) uses your exported AWS_* env vars.
set -euo pipefail
cd "$(dirname "$0")"

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

# The chart creates ClusterRoles, CRDs and webhooks — cluster-scoped, none of which the
# deployer SA may create. Gate on `create clusterroles` (the real admin test).
if ! kubectl auth can-i create clusterroles >/dev/null 2>&1; then
  echo "ERROR: this identity is not cluster-admin — installing the controller needs it."
  echo "  context: $(kubectl config current-context 2>/dev/null || echo none)"
  echo
  echo "  Run ./00-rbac-kubeconfig.sh first — it sets local-admin as your current context."
  echo "  Or switch to it:  kubectl config use-context local-admin@k8s-3tier"
  exit 1
fi

REGION="${REGION:-${AWS_REGION:-ap-south-1}}"      # env, not `aws configure` (creds are env-only)
CLUSTER_NAME="${CLUSTER_NAME:-kubernetes}"

# The controller authenticates with the static keys in secret/aws-secret. Fail early if missing.
if ! kubectl -n kube-system get secret "$AWS_SECRET" >/dev/null 2>&1; then
  echo "ERROR: secret/${AWS_SECRET} not found in kube-system. Run ./00-rbac-kubeconfig.sh first."
  exit 1
fi

# ── Node providerID ──────────────────────────────────────────────────────────
# kubeadm sets no providerID (no cloud-provider). The controller needs it to map each Node
# to its EC2 instance id when registering NLB instance targets; without it, targets never
# register and the NLB has no healthy backends. Patch any node that lacks one.
for NODE in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
  [ -n "$(kubectl get node "$NODE" -o jsonpath='{.spec.providerID}')" ] && continue
  IP=$(kubectl get node "$NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
  [ -n "$IP" ] || { echo "SKIP ${NODE}: no InternalIP"; continue; }
  read -r ID AZ <<<"$(aws ec2 describe-instances --region "$REGION" \
        --filters "Name=private-ip-address,Values=${IP}" "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[].[InstanceId,Placement.AvailabilityZone]' --output text)"
  [ -n "${ID:-}" ] && [ "$ID" != "None" ] || { echo "SKIP ${NODE} (${IP}): no running instance"; continue; }
  kubectl patch node "$NODE" -p "{\"spec\":{\"providerID\":\"aws:///${AZ}/${ID}\"}}"
  echo "providerID ${NODE} -> aws:///${AZ}/${ID}"
done

# Discover the VPC + public subnets from a node's InternalIP.
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
VPC_ID="${VPC_ID:-$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=private-ip-address,Values=${NODE_IP}" \
  --query 'Reservations[].Instances[].VpcId' --output text)}"
SUBNETS="${SUBNETS:-$(aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=map-public-ip-on-launch,Values=true" \
  --query 'Subnets[].SubnetId' --output text)}"

echo "cluster=${CLUSTER_NAME} region=${REGION} vpc=${VPC_ID}"
echo "public subnets: ${SUBNETS}"

# Tag subnets so the controller can auto-discover where to place internet-facing LBs.
for S in $SUBNETS; do
  aws ec2 create-tags --region "$REGION" --resources "$S" \
    --tags Key=kubernetes.io/role/elb,Value=1 \
           "Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=shared"
done

helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

kubectl apply -k "github.com/aws/eks-charts/stable/aws-load-balancer-controller/crds?ref=master"

# Pin the controller to the CONTROL-PLANE node. Its admission webhook is called by the API
# server; on kubeadm the API server (host-networked on the control-plane) cannot reliably reach
# a webhook pod sitting on a worker across the CNI overlay -> "context deadline exceeded" on every
# Service create. Co-locating webhook + API server on one node fixes that. replicaCount=1 because
# there is one control-plane node.
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set region="$REGION" \
  --set vpcId="$VPC_ID" \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set replicaCount=1 \
  --set 'nodeSelector.node-role\.kubernetes\.io/control-plane=' \
  --set 'tolerations[0].key=node-role.kubernetes.io/control-plane' \
  --set 'tolerations[0].operator=Exists' \
  --set 'tolerations[0].effect=NoSchedule'

# No IRSA on kubeadm, so feed the controller the static keys from the Secret. This adds
# env AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY (the Secret's key names) to the deployment.
kubectl set env deployment/aws-load-balancer-controller -n kube-system \
  --from=secret/"$AWS_SECRET"

# This chart regenerates its self-signed webhook cert on every helm upgrade, but a no-op upgrade
# does not restart the pods to load it -> the webhook caBundle and the served cert drift apart
# ("x509: signed by unknown authority"). Force the pods to reload the current cert.
kubectl -n kube-system rollout restart deployment/aws-load-balancer-controller

kubectl -n kube-system rollout status deploy/aws-load-balancer-controller
