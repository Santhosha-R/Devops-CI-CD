#!/usr/bin/env bash
# Apply the shared MongoDB — the ONE database all three setups connect to.
# Idempotent (safe to re-run). This is the only script that creates the database;
# the per-setup uninstalls never touch it, so it survives every batch reset.
#
# Prereq: EBS CSI driver + the ebs-sc StorageClass (pre-setup/01-ebs-csi-driver.sh).
set -euo pipefail
cd "$(dirname "$0")"

kubectl apply -f 00-namespace.yaml
kubectl apply -f 01-secret.yaml
kubectl apply -f 02-service.yaml
kubectl apply -f 03-statefulset.yaml

echo "waiting for mongo to be ready…"
kubectl -n database rollout status statefulset/mongo --timeout=180s

echo
kubectl -n database get pods,pvc,svc
cat <<'EOF'

MongoDB is up. Apps reach it cross-namespace at:
  mongo-service.database.svc.cluster.local:27017
EOF
