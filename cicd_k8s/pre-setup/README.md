# Pre-setup

**Two identities, one bootstrap.** A least-privilege `deployer` for CI, and a `local-admin` for
installing cluster infrastructure from your laptop (a long-lived admin token, so you never depend
on `~/.kube/config` — which dies when the cluster is rebuilt).

You apply `rbac-admin.yaml` once on the cluster; `00` does everything else from the admin token.

| File / step                           | Gives you                              | Who runs it | Needed by       |
| ------------------------------------- | -------------------------------------- | ----------- | --------------- |
| `rbac-admin.yaml`                     | `local-admin` SA (cluster-admin)       | admin, once | the bootstrap   |
| `00-rbac-kubeconfig.sh`               | admin kc → `rbac-deployer.yaml` → deployer kc → `aws-secret` → **prompts your domain → `demo.env`** | you | everything |
| `01-ebs-csi-driver.sh`                | EBS volumes for PVCs (`ebs-sc` class)  | current ctx | database        |
| `02-aws-load-balancer-controller.sh`  | `type: LoadBalancer` -> real NLB       | current ctx | `../ingress-nginx` |
| `05-ecr-setup.sh`                        | ECR repos (frontend_react, backend_node) | you       | all CI          |
| `03-install-cert-manager.sh`             | cert-manager platform (+ route53-creds) | you, once  | `../ingress-nginx` (Setup 1) |
| `04-install-argocd.sh`                   | ArgoCD GitOps platform (optional)      | you, once   | `../istio` (Setup 3) |
| `06-acm-cert.sh`                         | ACM wildcard cert (`*.$DEMO_DOMAIN`, DNS-validated) → prints `ACM_ARN` | you, once | `../gateway-api`, `../istio` (Setups 2 & 3) |

**Why an admin identity:** installing a driver creates a StorageClass, a CSIDriver, CRDs and
cluster RBAC, and patching `providerID` needs `patch nodes` — all cluster-admin. The `deployer` is
deliberately scoped to the app namespaces and must not do those, so `local-admin` (bound to the
built-in `cluster-admin`) drives `01`/`02`. `deployer` is only for deploying apps in CI.

`02` also patches `spec.providerID` on each node (folded in — kubeadm leaves it empty) so the
controller can register the NLB's instance targets. The EBS driver needs none of that — it
self-discovers its instance via IMDS — so the database path is just `00` + `01`.

## AWS authentication — Secret, not node IAM

Both drivers authenticate to AWS with static keys in **`secret/aws-secret`** (`kube-system`), which
`00` creates from your environment:

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
```

- The EBS driver reads them via the chart's `awsAccessSecret` values.
- The LB controller gets them injected as env vars (`kubectl set env ... --from=secret/aws-secret`).

The IAM **user** behind those keys needs EBS + ELB permissions (`AdministratorAccess`, or
`AmazonEBSCSIDriverPolicy` + `AWSLoadBalancerControllerIAMPolicy` attached to the user).

**Trade-off, own it in an interview:** static long-lived keys sit in the cluster. Anyone who can
read that Secret has your AWS keys, and they do not rotate. It is the simple path for a lab; the
production answer is **IRSA** on EKS, or **node IAM** (an instance profile on each node) on kubeadm —
no keys in the cluster at all. Keys in a Secret is the AWS analogue of the `insecure-skip-tls-verify`
choice: fine here, name the cost.

## Run

**1. Create the admin SA (once, on the cluster — needs existing admin):**

```bash
kubectl apply -f rbac-admin.yaml
kubectl -n kube-system get secret local-admin-token -o jsonpath='{.data.token}' | base64 -d ; echo
```

Copy that token and the master's **public** url (`https://<public-ip>:6443`).

**2. Bootstrap everything (locally, one run):**

```bash
export AWS_ACCESS_KEY_ID=...  AWS_SECRET_ACCESS_KEY=...   # optional; it prompts otherwise
./00-rbac-kubeconfig.sh
```

Paste the admin token + url. `00` then, from that one token: adds `local-admin@k8s-3tier` to your
`~/.kube/config` and makes it current (so plain `kubectl` is admin), applies `rbac-deployer.yaml`,
writes `kubeconfig-deployer.yaml` (for CI), and creates `aws-secret`. It also **asks for your Route53
domain** (default `hobbyez.com`), auto-resolves its hosted-zone id, and writes `pre-setup/demo.env` —
every install/uninstall script reads it, so students use their own domain with no code edits. (Update
the `frontend_react` / `backend_node` app repos with your domain separately.)
A token over ~1024 chars can't be pasted (terminal limit) — `export SA_TOKEN=<token>` and re-run.

**3. Install the drivers with the admin kubeconfig — from your laptop, no master, no scp:**

```bash
export AWS_ACCESS_KEY_ID=...  AWS_SECRET_ACCESS_KEY=...  AWS_REGION=ap-south-1
./01-ebs-csi-driver.sh                 # database disks — this alone is enough for the DB
./02-aws-load-balancer-controller.sh   # only if you also want the NLB (also patches providerID)
```

`01`/`02` use your current kubectl context, which `00` set to `local-admin` — so nothing to
`export`. (Switch back any time with `kubectl config use-context <your-old-context>`.)

`kubeconfig-deployer.yaml` is the CI credential — hand it to Jenkins/Actions/ArgoCD.

The drivers read `aws-secret` (seeded in step 2) for AWS auth; region/VPC/subnets are auto-detected.

## CI access (step 00)

`rbac-deployer.yaml` creates one ServiceAccount, `cicd/deployer`, with one ClusterRole and one
ClusterRoleBinding:

- **workload control in every namespace** — deployments, statefulsets, services, secrets,
  configmaps, ingresses, PVCs, HPAs, jobs
- **create namespaces**, so a pipeline can apply its own `00-namespace.yaml`
- **read-only** on nodes, PVs, storageclasses, CRDs
- **cannot** touch RBAC, CRDs, webhooks, or delete namespaces

The **app** namespaces are not declared here — each app repo ships its own, and a ClusterRoleBinding
does not need them to exist. Only `cicd` is declared, because nothing else owns it and the
ServiceAccount lives in it.

`00-rbac-kubeconfig.sh` runs with the **admin token**: it adds the `local-admin` context to
`~/.kube/config`, applies `rbac-deployer.yaml`, then reads the deployer token with that admin
context to write `kubeconfig-deployer.yaml` (insecure-skip-tls-verify). You never paste the
deployer token yourself.

Read the deployer token + url by hand any time (on the master):

```bash
kubectl -n cicd get secret deployer-token -o jsonpath='{.data.token}' | base64 -d   # token
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'            # url (private — use the public ip)
```

### TLS: no CA, `insecure-skip-tls-verify`

The kubeconfig carries `insecure-skip-tls-verify: true` instead of `certificate-authority-data`.
The two are mutually exclusive — kubectl rejects a kubeconfig holding both.

This is a deliberate trade. It buys two things:

- **No CA to move around.** The base64 CA is ~1500 characters, and a terminal truncates a single
  input line at 1024 bytes, so it cannot be pasted at a prompt at all.
- **The API server certificate no longer matters.** kubeadm signs it with the node's *private* ip
  only, so reaching the cluster on its public ip would otherwise fail with
  `x509: certificate is valid for 10.96.0.1, 172.31.41.8, not <public-ip>`. Skipping verification
  sidesteps that, with no need to reissue the cert.

What it costs: the client never verifies the server, so the connection can be man-in-the-middled.
The token still authenticates *you* to the cluster, and RBAC still constrains what you can do — but
an attacker who can intercept the connection can impersonate the API server and harvest that token.

**Say this out loud in an interview.** "I used `insecure-skip-tls-verify` because the kubeadm cert
only lists the private ip. In production I'd add the public ip to the cert SANs with
`kubeadm init phase certs apiserver --apiserver-cert-extra-sans`, put an Elastic IP on the master so
it stops changing, and pin the cluster CA in the kubeconfig." That answer beats either choice on
its own.

### The API server URL

On the master, that last command returns the node's **private** ip (`https://172.31.x.x:6443`).
Nothing outside the VPC — your laptop, Jenkins, GitHub Actions — can reach it. Build the public URL
from EC2 instance metadata instead:

```bash
T=$(curl -sX PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
IP=$(curl -s -H "X-aws-ec2-metadata-token: $T" http://169.254.169.254/latest/meta-data/public-ipv4)
echo "https://${IP}:6443"
```

One thing must be true: the control-plane security group allows `:6443` from your ip. Check yours
with `curl -s https://checkip.amazonaws.com`.

Because TLS is not verified, the certificate SANs do not matter — you can point at the public ip
without touching the API server.

> An EC2 public ip changes on stop/start, which invalidates every kubeconfig pointing at it. Attach
> an **Elastic IP** to the master so it stays put. (This already bit us once: the master moved from
> `13.127.24.5` to `13.207.69.208`.)

One file, three consumers:

```bash
# local
export KUBECONFIG=$PWD/kubeconfig-deployer.yaml

# jenkins — credential type "Secret file", id: kubeconfig-deployer
#   withCredentials([file(credentialsId: 'kubeconfig-deployer', variable: 'KUBECONFIG')]) {
#     sh 'kubectl -n backend set image deploy/backend backend=$IMAGE'
#   }

# github actions
gh secret set KUBECONFIG < kubeconfig-deployer.yaml
#   - run: echo "${{ secrets.KUBECONFIG }}" > kc.yaml && KUBECONFIG=kc.yaml kubectl apply -f k8s/

# argocd (cluster registered as an external target)
argocd cluster add deployer@k8s-3tier --kubeconfig kubeconfig-deployer.yaml
```

The file is a cluster credential — it is in `.gitignore`, keep it there.

## Verify

```bash
kubectl get pods -n kube-system | grep -E 'ebs-csi|load-balancer'   # all Running
kubectl get storageclass                                            # ebs-sc (default)
```

Prove EBS provisioning end to end:

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ebs-sc
  resources:
    requests:
      storage: 1Gi
EOF

kubectl get pvc test-pvc        # Pending until a Pod uses it — that is correct
kubectl delete pvc test-pvc
```

## Interview points

- **Why a CSI driver at all** — Kubernetes has no idea how to create an AWS disk. The EBS CSI
  driver is the plugin that turns a PVC into a real `aws ec2 create-volume`. No driver, and every
  PVC sits in `Pending`.
- **`WaitForFirstConsumer`** — the biggest gotcha with EBS. An EBS volume lives in one AZ and can
  only attach to a node in that AZ. Binding immediately would create the disk in a random AZ and
  the Pod might be unschedulable. This setting delays disk creation until the scheduler picks the
  node, then creates it in the right AZ.
- **`reclaimPolicy: Retain`** — for a database. Delete the PVC and the EBS volume survives, so a
  bad `kubectl delete` doesn't destroy the data. Cost of that is orphaned volumes to clean up by
  hand. App tiers can use `Delete`.
- **Why the database is a StatefulSet, not a Deployment** — a StatefulSet gives each Pod a stable
  identity and its own PVC via `volumeClaimTemplates`, so `mongo-0` reattaches to the same volume
  after a restart. Deployment Pods would share or lose one.
- **How the drivers reach AWS** — three options: IRSA (bind a ServiceAccount to an IAM role via an
  OIDC provider — EKS only), node IAM (an instance profile on each node), or static keys in a
  Secret. This is kubeadm with no OIDC provider, so IRSA is out; we use the Secret. Its cost is
  long-lived keys living in the cluster — the simple-lab choice, same shape as the insecure-TLS one.
- **`providerID`** — EKS sets it; kubeadm does not. The Load Balancer Controller reads it to map a
  Node to an EC2 instance ID when registering NLB instance targets. Without it, target
  registration silently fails. `02` folds in the providerID patch for exactly this reason.
- **`allowVolumeExpansion`** — you can grow a PVC in place later. You can never shrink it.
- **ClusterRole vs Role** — a ClusterRole is just a named set of rules. What decides the *scope* is
  the binding: a ClusterRoleBinding applies it in every namespace, a RoleBinding applies the same
  rules in one. We use a ClusterRoleBinding so adding an app namespace needs no RBAC change.
- **What that costs, and know this before you are asked** — cluster-wide write on Pods and Secrets
  is close to cluster-admin in practice. This token can read any Secret in `kube-system`, including
  other ServiceAccounts' tokens, and can schedule a Pod that mounts a privileged SA. It cannot edit
  RBAC directly, but it can reach an identity that can. Treat the kubeconfig as an admin credential.
  The hardening step is to swap the ClusterRoleBinding for one RoleBinding per app namespace —
  identical rules, blast radius drops to those namespaces — at the cost of one RoleBinding each time
  a namespace is added. Say that tradeoff out loud and you have answered the question properly.
- **Why not just bind `cluster-admin`** — enumerating resources still buys something real: the token
  cannot create CRDs, mutating webhooks, or ClusterRoleBindings, so an accidental `kubectl apply` of
  the wrong manifest fails loudly instead of silently reshaping the cluster.
- **Why a Secret for the token** — since 1.24 a ServiceAccount no longer gets an automatic,
  never-expiring token. `kubectl create token` issues a short-lived one, which is what you want for
  humans. CI that runs unattended needs a static credential, so we declare the
  `kubernetes.io/service-account-token` Secret explicitly. The tradeoff is that it never expires:
  rotate it by deleting the Secret and re-running step 00.
- **ServiceAccount, not a client certificate** — an x509 cert cannot be revoked in Kubernetes
  short of rotating the cluster CA. Delete the SA and its token dies instantly.

## Cleanup

```bash
helm uninstall aws-load-balancer-controller -n kube-system
helm uninstall aws-ebs-csi-driver -n kube-system
kubectl delete -f storageclass.yaml
```

Delete workloads with PVCs first. With `Retain`, the EBS volumes stay in AWS — remove them with
`aws ec2 delete-volume` once you are sure.
