# k8s-networks — Kubernetes edge networking, interview-ready

Three ways to get traffic into a Kubernetes cluster, compared and explained for **interviews** — short speakable bullets, real-world config, current-through-2026 facts, and a diagram each. Every guide is **synced to the `cicd_k8s` demo** (Setup 1 / 2 / 3), so you can explain the theory *and* point to what you built.

![comparison](ingress-vs-envoy-gateway-vs-istio.png)

## Start here
- **[ingress-vs-envoy-gateway-vs-istio.md](ingress-vs-envoy-gateway-vs-istio.md)** — the head-to-head comparison + 16 interview Q&A. Read this first.

## Deep dives (one folder each — README + architecture diagram)
| Guide | What it is | Demo |
|---|---|---|
| **[ingress-nginx/](ingress-nginx/)** | NGINX Ingress Controller — the classic Ingress API (⚠️ **retired March 2026**) | Setup 1 |
| **[envoy-gateway-api/](envoy-gateway-api/)** | Gateway API + Envoy Gateway — the role-oriented **successor to Ingress** | Setup 2 |
| **[istio/](istio/)** | Istio service mesh — ingress **plus** pod-to-pod mTLS & observability | Setup 3 |

## The one-line frame
> **Ingress = edge only · Gateway API = modern portable edge · Istio = edge *plus* a mesh.**
>
> Order of operational cost: **NGINX < Envoy Gateway < Istio.** Decision heuristic: *"Do I need service-to-service security/observability? Yes → Istio. No → Gateway API."*

## What makes these interview-strong
- **Current:** ingress-nginx retirement (March 2026), the IngressNightmare CVE-2025-1974, Gateway API GA v1.0→v1.4, Istio Ambient GA (1.24).
- **Real-world config:** the annotations/CRDs/policies companies actually turn on.
- **62 interview Q&A** across the four docs, tagged basic → advanced.
- Each `architecture.png` is a simple, labelled diagram; the `.svg` source sits beside it for edits.
