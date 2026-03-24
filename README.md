# Homelab

A self-hosted infrastructure platform running on bare metal, fully automated from empty disk to running services. Built on k3s with GitOps-driven continuous delivery.

## Overview

This project provisions and operates a 3-node high-availability Kubernetes cluster at home. The entire stack is declarative — infrastructure is defined as code, services are deployed via Git push, and the cluster self-heals through ArgoCD reconciliation.

No ports are exposed to the internet. All external access flows through a Cloudflare Tunnel, with TLS terminated at the Cloudflare edge.

## Hardware

| Node | Role | Description |
|------|------|-------------|
| onyi | control plane + worker | k3s server |
| thor | control plane + worker | k3s server |
| mimir | control plane + worker | k3s server |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Cloudflare Edge                         │
│              (DNS, TLS termination, CDN)                    │
└──────────────────────┬──────────────────────────────────────┘
                       │ QUIC tunnel
┌──────────────────────▼──────────────────────────────────────┐
│                   k3s Cluster                               │
│                                                             │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │
│  │ cloudflared │──│   Traefik   │──│     Services        │ │
│  │  (tunnel)   │  │ (L7 routing)│  │ ArgoCD, Grafana,    │ │
│  └─────────────┘  └─────────────┘  │ Longhorn, apps ...  │ │
│                                     └─────────────────────┘ │
│  ┌──────────────────────────────────────────────────────┐   │
│  │              Cilium CNI + Hubble                     │   │
│  │        (pod networking, network policy, eBPF)        │   │
│  └──────────────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────────────┐   │
│  │                    kube-vip                           │   │
│  │          (HA control plane + LoadBalancer)            │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## Repository Structure

```
.
├── Makefile                    # Root orchestrator
├── metal/                      # Bare metal provisioning (Ansible)
│   ├── PXE boot
│   ├── k3s cluster deployment
│   └── Cilium + kube-vip installation
├── external/                   # External dependencies (Terraform)
│   ├── Cloudflare tunnel
│   ├── DNS records
│   └── Kubernetes secrets
├── system/                     # Cluster infrastructure (ArgoCD)
│   ├── argocd/                 # GitOps engine (self-managed)
│   ├── traefik/                # Ingress controller
│   ├── cloudflared/            # Tunnel connector
│   ├── longhorn/               # Distributed block storage
│   ├── monitoring/             # Prometheus + Grafana
│   ├── loki/                   # Log aggregation (Loki + Alloy)
│   └── hubble-ui/              # Network observability
├── platform/                   # Shared platform services (ArgoCD)
└── apps/                       # User applications (ArgoCD)
    ├── homepage/               # Service dashboard
    └── obsidian-livesync/      # Obsidian sync server (CouchDB)
```

## Bootstrap

The cluster is provisioned in three stages. Each stage builds on the previous one.

```bash
# Stage 1: Bare metal — PXE boot nodes, install k3s, deploy Cilium + kube-vip
make -C metal

# Stage 2: External — Create Cloudflare tunnel, inject secrets
make external

# Stage 3: System — Bootstrap ArgoCD, which then deploys everything else
make bootstrap
```

After stage 3, ArgoCD takes full control. Every directory under `system/`, `platform/`, and `apps/` becomes an ArgoCD Application automatically via an ApplicationSet. Changes are deployed by pushing to `main`.

## GitOps Workflow

```
Push to main → ArgoCD detects change → Syncs to cluster → Service updated
```

ArgoCD is bootstrapped using Ansible with `helm_template` and server-side apply. After initial bootstrap, ArgoCD manages itself — updates to `system/argocd/` are self-applied.

The ApplicationSet uses a Git directory generator to scan for subdirectories:

```yaml
generators:
  - git:
      directories:
        - path: system/*
        - path: platform/*
        - path: apps/*
```

Each directory can contain either a Helm chart (`Chart.yaml` + `values.yaml`) or plain Kubernetes manifests. ArgoCD handles both.

## Networking

All external traffic flows through a single path:

```
User → Cloudflare (TLS) → Tunnel → cloudflared pod → Traefik → Service
```

There are no open ports, no public IPs, and no need for cert-manager or external-dns. Cloudflare handles DNS (via wildcard CNAME) and TLS (terminated at edge). Traefik handles L7 routing based on hostname. Services that need authentication use Cloudflare Access (Zero Trust).

Internal networking is handled by Cilium, which replaces kube-proxy with eBPF for service load balancing. kube-vip provides a floating VIP for the HA control plane and assigns external IPs to LoadBalancer services.

## Adding a New Application

1. Create a directory under `apps/` with your manifests or Helm chart:

```bash
mkdir apps/my-app
```

2. Add your Kubernetes resources (deployment, service, ingress):

```yaml
# apps/my-app/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  namespace: my-app
spec:
  replicas: 1
  ...
```

3. If the app needs an ingress, add a Traefik-compatible Ingress resource:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  namespace: my-app
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
spec:
  ingressClassName: traefik
  rules:
    - host: my-app.owoicho.org
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app
                port:
                  number: 8080
```

4. If the app needs secrets, create them before deploying:

```bash
kubectl create secret generic my-app-secret \
  --from-literal=key=value -n my-app
```

5. Push to `main`. ArgoCD deploys it automatically.

## Stack

| Component | Version | Purpose |
|-----------|---------|---------|
| k3s | latest | Lightweight Kubernetes distribution |
| Cilium | 1.16.1 | CNI, network policy, kube-proxy replacement |
| kube-vip | — | HA control plane VIP, LoadBalancer IPs |
| ArgoCD | 7.5.2 (chart) | GitOps continuous delivery |
| Traefik | 33.2.1 (chart) | Ingress controller, L7 routing |
| Cloudflare Tunnel | — | Secure external access, no open ports |
| Longhorn | 1.11.1 | Distributed replicated block storage |
| Prometheus | 82.13.0 (chart) | Metrics collection and alerting |
| Grafana | — | Dashboards and visualization |
| Loki | 6.54.0 (chart) | Log aggregation |
| Alloy | 0.12.0 (chart) | Log collection (Promtail replacement) |
| Hubble | — | Network observability via eBPF |

## Acknowledgements

Inspired by [khuedoan/homelab](https://github.com/khuedoan/homelab).