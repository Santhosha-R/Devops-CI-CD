#!/usr/bin/env bash
# Create the ECR repositories the CI pipelines push to (frontend + backend).
# AWS-only — no cluster needed. Uses your exported AWS_* creds. Idempotent.
#
#   export AWS_ACCESS_KEY_ID=...  AWS_SECRET_ACCESS_KEY=...  AWS_REGION=ap-south-1
#   ./ecr-setup.sh                 # defaults: frontend_react backend_node (the git repo names)
#   ./ecr-setup.sh api web         # or name your own
set -euo pipefail
export AWS_PAGER=""

REGION="${AWS_REGION:-ap-south-1}"
# One ECR repo per git repo, same name. Each Jenkinsfile's IMAGE must be
# <registry>/<this-name> (e.g. .../frontend_react, .../backend_node).
if [ "$#" -gt 0 ]; then REPOS=("$@"); else REPOS=(frontend_react backend_node); fi

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
echo "registry: ${REGISTRY}   repos: ${REPOS[*]}"
echo

for r in "${REPOS[@]}"; do
  if aws ecr describe-repositories --region "$REGION" --repository-names "$r" >/dev/null 2>&1; then
    echo "  exists: $r"
  else
    # scan-on-push finds CVEs; IMMUTABLE tags match the pipelines' unique BUILD_NUMBER tags
    # (a tag can never be overwritten — the deployed image is exactly what CI built).
    aws ecr create-repository --region "$REGION" --repository-name "$r" \
      --image-scanning-configuration scanOnPush=true \
      --image-tag-mutability IMMUTABLE \
      --query 'repository.repositoryUri' --output text | sed 's/^/  created: /'
  fi
done

cat <<EOF

Registry:  ${REGISTRY}
Login:     aws ecr get-login-password --region ${REGION} | docker login --username AWS --password-stdin ${REGISTRY}
Images:
EOF
for r in "${REPOS[@]}"; do echo "  ${REGISTRY}/${r}"; done

cat <<EOF

Pulling from the cluster: the nodes use static keys (secret method), not node IAM, so pods need an
image-pull secret. Create one per app namespace (the ECR token lasts ~12h — re-run to refresh, or
run it from a CronJob):

  for ns in frontend backend; do
    kubectl -n \$ns create secret docker-registry ecr-creds \\
      --docker-server=${REGISTRY} --docker-username=AWS \\
      --docker-password="\$(aws ecr get-login-password --region ${REGION})" \\
      --dry-run=client -o yaml | kubectl apply -f -
  done
EOF
