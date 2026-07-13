#!/usr/bin/env bash
# One-run bootstrap. You apply rbac-admin.yaml on the cluster first (needs existing admin);
# everything else is automated from the admin token:
#
#   STEP 1  paste admin token + url
#             -> local-admin context in ~/.kube/config, set current (plain kubectl = admin)
#             -> apply rbac-deployer.yaml       (creates the deployer SA)
#             -> kubeconfig-deployer.yaml       (scoped file, for Jenkins/Actions/ArgoCD)
#   STEP 2  AWS keys (aws-configure style)
#             -> secret/aws-secret in kube-system   (EBS + LB drivers read it)
#
# Re-runnable: every step is idempotent. TLS uses insecure-skip-tls-verify (no CA).
set -euo pipefail
cd "$(dirname "$0")"

ask()  { printf '\033[1;33m%s\033[0m' "$1"; }
step() { printf '\n\033[1;36m─── STEP %s — %s\033[0m\n\n' "$1" "$2"; }
trim() { printf '%s' "$1" | tr -d '[:space:]'; }
mask() { local v="$1"; if [ ${#v} -le 8 ]; then printf '****'; else printf '%s****%s' "${v:0:4}" "${v: -4}"; fi; }

write_kubeconfig() {   # $1=file  $2=user  $3=token  $4=server  $5=namespace
  ( umask 077                       # 600 from creation — it holds a token
  cat > "$1" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: k8s-3tier
    cluster:
      server: $4
      insecure-skip-tls-verify: true
users:
  - name: $2
    user:
      token: $3
contexts:
  - name: $2@k8s-3tier
    context:
      cluster: k8s-3tier
      user: $2
      namespace: $5
current-context: $2@k8s-3tier
EOF
  )
  chmod 600 "$1"
}


# ── preflight: the CLIs this bootstrap (and every setup) needs ────────────────
# macOS -> Homebrew · Ubuntu/Linux -> snap (kubectl, helm) + apt (aws). Skips whatever is present.
require_tools() {
  local os miss=""
  os=$(uname -s)
  for t in kubectl helm aws; do command -v "$t" >/dev/null 2>&1 || miss="$miss $t"; done
  [ -z "$miss" ] && { echo "tools: kubectl, helm, aws present ✓"; return 0; }
  echo "installing missing tools:$miss"
  for t in $miss; do
    case "$os" in
      Darwin)
        command -v brew >/dev/null 2>&1 || { echo "Homebrew not found — install it from https://brew.sh, then re-run."; exit 1; }
        case "$t" in aws) brew install awscli ;; *) brew install "$t" ;; esac ;;
      Linux)
        case "$t" in
          aws) sudo apt-get update -qq && sudo apt-get install -y awscli ;;
          *)   sudo snap install "$t" --classic ;;
        esac ;;
      *) echo "unsupported OS ($os) — install $t manually."; exit 1 ;;
    esac
  done
  for t in $miss; do command -v "$t" >/dev/null 2>&1 || { echo "$t still missing — install manually."; exit 1; }; done
}
require_tools


# ── STEP 1 ────────────────────────────────────────────────────────────────────
step 1 "Admin context (into ~/.kube/config) + deployer RBAC"
cat <<'EOF'
  First, on the cluster (needs existing admin), create the admin SA and read its token:
    kubectl apply -f rbac-admin.yaml
    kubectl -n kube-system get secret local-admin-token -o jsonpath='{.data.token}' | base64 -d ; echo
  Paste that token + the master's PUBLIC url below.
  (token over ~1024 chars can't be pasted — export SA_TOKEN=<token> and re-run.)
EOF
echo

if [ -n "${SA_TOKEN:-}" ]; then
  TOKEN=$(trim "$SA_TOKEN"); echo "  admin token: from SA_TOKEN"
else
  ask "admin token (hidden): "; read -rs TOKEN || TOKEN=""; echo; TOKEN=$(trim "$TOKEN")
fi
[ -n "$TOKEN" ] || { echo "ERROR: no token given."; exit 1; }

ask "cluster url (https://HOST:6443): "; read -r SERVER || SERVER=""
SERVER=$(trim "$SERVER"); SERVER="${SERVER%/}"
case "$SERVER" in https://*) ;; *) echo "ERROR: url must start with https:// (got '${SERVER}')"; exit 1 ;; esac

# Admin goes straight into ~/.kube/config as a context and becomes current, so plain kubectl
# (and 01/02) is admin with no KUBECONFIG juggling. These are additive — your other contexts stay.
KUBE_CONFIG="${KUBECONFIG_MAIN:-$HOME/.kube/config}"
mkdir -p "$(dirname "$KUBE_CONFIG")"
kubectl --kubeconfig="$KUBE_CONFIG" config set-cluster     k8s-3tier --server="$SERVER" --insecure-skip-tls-verify=true >/dev/null
kubectl --kubeconfig="$KUBE_CONFIG" config set-credentials local-admin --token="$TOKEN" >/dev/null
kubectl --kubeconfig="$KUBE_CONFIG" config set-context     local-admin@k8s-3tier --cluster=k8s-3tier --user=local-admin --namespace=kube-system >/dev/null
kubectl --kubeconfig="$KUBE_CONFIG" config use-context     local-admin@k8s-3tier >/dev/null
echo "  added context local-admin@k8s-3tier to ${KUBE_CONFIG} (now current)"

# Use that admin context for the rest of this script (ignore any KUBECONFIG you had exported).
export KUBECONFIG="$KUBE_CONFIG"

# Verify it is really cluster-admin (and the url is reachable) before we lean on it.
if ! kubectl auth can-i create clusterrolebindings >/dev/null 2>&1; then
  echo "ERROR: this token is not cluster-admin, or ${SERVER} is unreachable."
  echo "       Did you 'kubectl apply -f rbac-admin.yaml' and paste local-admin-token?"
  exit 1
fi
echo "  admin access: ok"

# The admin applies the deployer RBAC — no separate master step.
kubectl apply -f rbac-deployer.yaml

# Build the deployer kubeconfig by reading its token with the admin (the SA token Secret is
# populated a moment after apply, so retry briefly).
echo -n "  reading deployer-token"
DTOKEN=""
for _ in $(seq 15); do
  DTOKEN=$(kubectl -n cicd get secret deployer-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
  [ -n "$DTOKEN" ] && break
  echo -n "." ; sleep 1
done
echo
[ -n "$DTOKEN" ] || { echo "ERROR: could not read deployer-token from ns cicd"; exit 1; }
write_kubeconfig kubeconfig-deployer.yaml deployer "$DTOKEN" "$SERVER" cicd
echo "  wrote kubeconfig-deployer.yaml (for CI)"


# ── STEP 2 ────────────────────────────────────────────────────────────────────
step 2 "AWS credentials -> secret/aws-secret"

# aws-configure style: if the env var is already set, show it masked and Enter keeps it.
if [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
  ask "AWS_ACCESS_KEY_ID [$(mask "$AWS_ACCESS_KEY_ID")]: "; read -r i || i=""; [ -n "$i" ] && AWS_ACCESS_KEY_ID="$i"
else
  ask "AWS_ACCESS_KEY_ID: "; read -r AWS_ACCESS_KEY_ID || AWS_ACCESS_KEY_ID=""
fi
if [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]; then
  ask "AWS_SECRET_ACCESS_KEY [**** set, Enter=keep]: "; read -rs i || i=""; echo; [ -n "$i" ] && AWS_SECRET_ACCESS_KEY="$i"
else
  ask "AWS_SECRET_ACCESS_KEY (hidden): "; read -rs AWS_SECRET_ACCESS_KEY || AWS_SECRET_ACCESS_KEY=""; echo
fi
AWS_ACCESS_KEY_ID=$(trim "${AWS_ACCESS_KEY_ID:-}")
AWS_SECRET_ACCESS_KEY=$(trim "${AWS_SECRET_ACCESS_KEY:-}")

if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
  echo "  (no AWS keys given — skipped aws-secret; create it later by re-running.)"
else
  # Keys via stdin (not --from-literal) so they never land in kubectl's argv / ps.
  printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\n' "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" \
    | kubectl create secret generic aws-secret -n kube-system --from-env-file=/dev/stdin --dry-run=client -o yaml \
    | kubectl apply -f -
  echo "  secret/aws-secret ready in kube-system"
fi


# ── STEP 3 ────────────────────────────────────────────────────────────────────
step 3 "Route53 domain for the demo -> pre-setup/demo.env"

# Every setup keys its hostnames, DNS records and ACM/Let's-Encrypt cert off ONE domain. Students each
# have their own domain + hosted zone, so enter yours once here; all install/uninstall scripts read
# pre-setup/demo.env. (You still update the frontend/backend *code* repos with your domain separately.)
DEF_DOMAIN="hobbyez.com"
[ -f demo.env ] && DEF_DOMAIN=$(sed -n 's/^DEMO_DOMAIN=//p' demo.env | head -1)
DEF_DOMAIN="${DEMO_DOMAIN:-$DEF_DOMAIN}"
ask "Route53 domain [${DEF_DOMAIN}]: "; read -r DEMO_DOMAIN || DEMO_DOMAIN=""
DEMO_DOMAIN=$(trim "${DEMO_DOMAIN:-$DEF_DOMAIN}")

# the keys from STEP 2 let the aws CLI look up the hosted zone id automatically
[ -n "${AWS_ACCESS_KEY_ID:-}" ] && export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
export AWS_REGION="${AWS_REGION:-ap-south-1}" AWS_PAGER=""

ZONE_ID=""
if aws sts get-caller-identity >/dev/null 2>&1; then
  ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "${DEMO_DOMAIN}." \
    --query "HostedZones[?Name=='${DEMO_DOMAIN}.'].Id | [0]" --output text 2>/dev/null | sed 's#/hostedzone/##')
  [ "$ZONE_ID" = None ] && ZONE_ID=""
fi
if [ -z "$ZONE_ID" ]; then
  echo "  couldn't auto-find the hosted zone for ${DEMO_DOMAIN} (no AWS creds yet, or no such zone)."
  ask "  Route53 hosted zone id (blank = fill in later): "; read -r ZONE_ID || ZONE_ID=""
  ZONE_ID=$(trim "$ZONE_ID")
else
  echo "  hosted zone for ${DEMO_DOMAIN}: ${ZONE_ID}"
fi

{ printf 'DEMO_DOMAIN=%s\n'    "$DEMO_DOMAIN"
  printf 'HOSTED_ZONE_ID=%s\n' "$ZONE_ID"
  printf 'AWS_REGION=%s\n'     "$AWS_REGION"
} > demo.env
echo "  wrote $(pwd)/demo.env  (every install/uninstall script reads this)"


cat <<EOF

─── DONE

  admin        context local-admin@k8s-3tier in ${KUBE_CONFIG} (current) — plain kubectl is admin
  deployer     kubeconfig-deployer.yaml — hand to Jenkins / GitHub Actions / ArgoCD
  aws-secret   in kube-system (if AWS keys were given)
  demo.env     domain=${DEMO_DOMAIN}  zone=${ZONE_ID:-<set later>}  — every setup reads this

  install the drivers now (plain kubectl is already admin — no export, no kubeconfig flag):
    ./01-ebs-csi-driver.sh                 # database disks
    ./02-aws-load-balancer-controller.sh   # NLB — also patches providerID

  Never commit kubeconfig-deployer.yaml. Rotate the AWS keys after the demo.
EOF
