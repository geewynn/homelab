# Homelab Kubernetes Platform

A three-node bare-metal Kubernetes homelab with automated node provisioning, high-availability control-plane access, eBPF networking, GitOps, encrypted storage, private administration and outbound-only application ingress.

The infrastructure is designed so a powered-off and empty bare-metal node can be provisioned to a GitOps-managed Kubernetes cluster without a USB installer or manual operating-system setup.

## What this project demonstrates

- bare-metal provisioning with Wake-on-LAN, PXE, TFTP, HTTP and Ubuntu Autoinstall.
- Ansible-driven OS and k3s bootstrap.
- LUKS2 disk encryption with TPM2-assisted unattended boot.
- three-server k3s with embedded etcd.
- kube-vip for a highly available control-plane endpoint.
- Cilium for Pod networking, eBPF Service load balancing and L2 `LoadBalancer` advertisements.
- Argo CD for GitOps reconciliation.
- Cloudflare Tunnel for public application access without inbound router port-forwarding.
- Tailscale for private SSH and Kubernetes administration.
- Longhorn for replicated persistent storage.
- Prometheus, Loki, Alloy, Grafana and Hubble and Clickhouse for observability.



# Architecture

## Network architecture

All devices are on the same `10.0.0.0/24` subnet, with no VLAN seperation. Both load balancers (kube-vip and Cilium) advertise their IP addresses using Address Resolution Protocol (ARP) and their announcement are visible across the same local network.

Both kube-vip and Cilium advertise addresses using ARP. Their advertisements are visible across the local LAN because ARP is a Layer-2 protocol and does not cross routed subnet boundaries.

```mermaid
flowchart TB
    Internet["Internet"] --> ISP["ISP / Home Router"]
    ISP -->|"WAN / uplink"| ER605["TP-Link Omada ER605<br/>Gateway: 10.0.0.1<br/>LAN: 10.0.0.0/24"]

    ER605 --> WS["Management Workstation<br/>10.0.0.52"]
    ER605 --> M["mimir<br/>10.0.0.50"]
    ER605 --> O["onyi<br/>10.0.0.51"]
    ER605 --> T["thor<br/>10.0.0.53"]

    subgraph K8S["Kubernetes Cluster"]
        direction TB
        M
        O
        T
        VIP["kube-vip<br/>10.0.0.200"]
        LB["Cilium LoadBalancer Pool<br/>10.0.0.208/28"]
        POD["Pod CIDR<br/>10.42.0.0/16"]
    end

    WS -. "Tailscale management overlay" .-> K8S
```
### Network summary

| Address / range | Purpose |
|---|---|
| `10.0.0.0/24` | homelab LAN |
| `10.0.0.1` | ER605 gateway, DHCP and DNS |
| `10.0.0.50` | `mimir` |
| `10.0.0.51` | `onyi` |
| `10.0.0.52` | management workstation |
| `10.0.0.53` | `thor` |
| `10.0.0.200` | kube-vip control-plane VIP |
| `10.0.0.208/28` | Cilium `LoadBalancer` pool |
| `10.42.0.0/16` | Kubernetes Pod CIDR |

kube-vip and Cilium both use Layer-2 advertisement on the LAN, but their responsibilities do not overlap: kube-vip owns the Kubernetes API VIP, while Cilium owns application `LoadBalancer` addresses.

---

## Provisioning and bootstrap

The below diagram describes the node setup flow from an empty bare metal to a GitOps-managed platform. The workstation provides the temporary PXE services, Ansible is used for the installation, k3s for the three-node control plane, and Argo CD for gitops.

```mermaid
flowchart TB

    GIT["Git Repository<br/>Ansible configuration"]
    WS["Workstation<br/>10.0.0.52<br/>Ansible · Terraform"]

    GIT --> WS

    WS --> WOL["Wake-on-LAN<br/>Power on target"]
    WS --> PXE["PXE Services<br/>dnsmasq + nginx"]

    PXE --> DHCP["Proxy DHCP"]
    PXE --> TFTP["TFTP<br/>GRUB · Kernel · initrd"]
    PXE --> HTTP["HTTP<br/>Ubuntu ISO · user-data"]

    WOL --> NODE["Bare-metal Node"]
    DHCP --> NODE
    TFTP --> NODE
    HTTP --> NODE

    NODE --> AUTO["Ubuntu Autoinstall<br/>cloud-init + Subiquity"]

    AUTO --> STATIC["Static IP"]
    AUTO --> SSH["SSH Keys"]
    AUTO --> ID["Node Identity"]

    STATIC --> LUKS["LUKS2 Disk Encryption"]
    SSH --> LUKS
    ID --> LUKS

    LUKS --> TPM["TPM2 Auto-Unlock"]
    TPM --> SECURE["Secure Boot + PCR Policy"]

    SECURE --> K3S["Install k3s"]

    K3S --> FIRST["First Server<br/>cluster-init"]
    K3S --> JOIN["Remaining Servers<br/>join cluster"]

    FIRST --> ETCD["3-Node Embedded etcd"]
    JOIN --> ETCD

    ETCD --> VIP["kube-vip<br/>10.0.0.200:6443"]
    VIP --> CILIUM["Cilium<br/>Pod + Service Networking"]
    CILIUM --> ARGO["Bootstrap Argo CD"]
    ARGO --> APPSET["Root ApplicationSet"]

    APPSET --> SYSTEM["system/*"]
    APPSET --> PLATFORM["platform/*"]
    APPSET --> APPS["apps/*"]

    SYSTEM --> GITOPS["GitOps Takes Over"]
    PLATFORM --> GITOPS
    APPS --> GITOPS
```
## PXE boot chain

A new node starts in its UEFI PXE environment and broadcasts a DHCP request. The ER605 supplies normal network configuration, while `dnsmasq` on the workstation operates in Proxy DHCP mode and provides PXE boot information.

The node then retrieves a network-enabled GRUB image and the Ubuntu kernel/initrd (initial ram disk) over TFTP. Once Linux is running, the installer switches to HTTP for the large Ubuntu ISO and the per-machine autoinstall configuration.

```mermaid
sequenceDiagram
    autonumber
    participant N as New Node
    participant R as ER605
    participant D as dnsmasq (10.0.0.52)
    participant H as nginx (10.0.0.52)

    N->>R: DHCPDISCOVER
    R-->>N: IP, gateway and DNS
    D-->>N: PXE boot information

    N->>D: PXE boot request
    N->>D: TFTP grubx64.efi
    N->>D: TFTP grub.cfg
    N->>D: TFTP kernel + initrd

    Note over N: GRUB selects the machine-specific config path

    N->>H: HTTP Ubuntu ISO
    N->>H: HTTP user-data / meta-data

    Note over N: Subiquity performs unattended installation
    N->>N: Reboot into installed Ubuntu
```

---


## Platform architecture

The below diagram shows the high level platform architecture consisting of the physical LAN and workstation, the three-node k3s/etcd cluster, the control-plane VIP, the major Kubernetes platform planes, the encrypted storage foundation and the GitOps control path.

```mermaid
flowchart TB

    INTERNET["Internet"]
    ISP["Home / ISP Router"]
    ER605["TP-Link Omada ER605<br/>Gateway: 10.0.0.1<br/>LAN: 10.0.0.0/24<br/>DHCP + DNS"]

    INTERNET --> ISP
    ISP -->|"WAN / Uplink"| ER605

    WS["Workstation<br/>10.0.0.52<br/>Ansible · Terraform · PXE"]
    ER605 --> WS

    subgraph CLUSTER["3-Node k3s Kubernetes Cluster"]
        direction TB

        subgraph NODES["Control Plane + Worker Nodes"]
            direction LR
            M["mimir<br/>10.0.0.50<br/>k3s · etcd"]
            O["onyi<br/>10.0.0.51<br/>k3s · etcd"]
            T["thor<br/>10.0.0.53<br/>k3s · etcd"]
        end

        VIP["kube-vip<br/>Control Plane VIP<br/>10.0.0.200:6443<br/>ARP + Leader Election"]

        M --- VIP
        O --- VIP
        T --- VIP

        subgraph NETWORK["Network Plane"]
            direction LR
            CILIUM["Cilium<br/>eBPF / kube-proxy replacement"]
            POD["Pod CIDR<br/>10.42.0.0/16"]
            LB["LoadBalancer Pool<br/>10.0.0.208/28"]
            HUBBLE["Hubble"]
        end

        CILIUM --> POD
        CILIUM --> LB
        CILIUM --> HUBBLE

        subgraph EDGE["Edge Plane"]
            direction LR
            CFD["cloudflared"]
            TRAEFIK["Traefik"]
            CERT["cert-manager"]
        end

        subgraph STORAGE["Storage Plane"]
            direction LR
            LONGHORN["Longhorn"]
            CNPG["CloudNativePG"]
            CH["ClickHouse"]
        end

        subgraph OBS["Observability Plane"]
            direction LR
            PROM["Prometheus"]
            LOKI["Loki"]
            ALLOY["Alloy"]
            GRAFANA["Grafana"]
        end

        subgraph APPLICATIONS["Applications"]
            direction LR
            HOME["Homepage"]
            LINK["Linkding"]
            OBSIDIAN["Obsidian LiveSync"]
            EXCAL["Excalidraw"]
        end

        NETWORK --> EDGE
        NETWORK --> STORAGE
        EDGE --> APPLICATIONS
        STORAGE --> APPLICATIONS

        ALLOY --> LOKI
        LOKI --> GRAFANA
        PROM --> GRAFANA

        SECURITY["Node Storage Foundation<br/>LUKS2 + TPM2 Auto-Unlock<br/>Secure Boot"]
    end

    ER605 --> M
    ER605 --> O
    ER605 --> T

    GIT["GitHub Repository<br/>system/* · platform/* · apps/*"]
    ARGO["Argo CD<br/>Root ApplicationSet"]
    RECON["Continuous Reconciliation<br/>Prune · Self-Heal · Server-Side Apply"]

    GIT --> ARGO
    ARGO --> RECON
    RECON --> CLUSTER
```



## Traffic flow

Application traffic and administrative traffic are separated. Public applications use Cloudflare Tunnel, workstation reaches the nodes using tailscale.

```mermaid
flowchart TB

    subgraph PUBLIC["Application Traffic"]
        direction TB

        USER["User / Browser"]
        CF["Cloudflare Edge<br/>DNS · TLS · Zero Trust"]
        CFD["cloudflared<br/>2 Replicas"]
        TRAEFIK["Traefik<br/>DaemonSet"]
        SVC["Kubernetes Service"]
        CILIUM["Cilium eBPF<br/>Service Load Balancing"]
        POD["Application Pod<br/>10.42.0.0/16"]

        USER -->|"HTTPS"| CF
        CF -->|"Existing outbound tunnel"| CFD
        CFD -->|"HTTP"| TRAEFIK
        TRAEFIK -->|"Ingress / Host match"| SVC
        SVC --> CILIUM
        CILIUM --> POD
    end

    subgraph ADMIN["Administrative Traffic"]
        direction TB

        OP["Operator"]
        TS["Tailscale Mesh<br/>WireGuard · tag:k3s"]

        M["mimir<br/>10.0.0.50"]
        O["onyi<br/>10.0.0.51"]
        T["thor<br/>10.0.0.53"]

        OP -->|"SSH / kubectl"| TS
        TS --> M
        TS --> O
        TS --> T
    end
```

**Application path:** `Browser → Cloudflare → cloudflared → Traefik → Service → Cilium → Pod`

**Workstation path:** `Engineer → Tailscale → k3s nodes`

The Cloudflare tunnel is established outbound from the cluster, so public applications do not require an inbound router port-forward. Tailscale provides a separate private management path for SSH and Kubernetes administration.

---


# GitOps

Ansible bootstraps Argo CD once. From that point, the repository is authoritative for Kubernetes state.

The root ApplicationSet scans:

```text
system/*
platform/*
apps/*
```

and generates one Argo CD Application per directory.

Automated synchronization uses pruning and self-healing so resources removed from Git are removed from the cluster and manual drift is reconciled back to the desired state.

---

# Storage

Longhorn is the default Kubernetes StorageClass and normally keeps two replicas of each volume across the three nodes.

Node disks are encrypted with LUKS2 underneath Longhorn, so persistent cluster data ultimately lands on encrypted storage.

ClickHouse uses a hot/cold storage policy:

```text
Longhorn -> hot tier
S3       -> cold tier
```

`linkding` uses a dedicated single-replica StorageClass with `Retain` reclaim policy where lower capacity usage is preferred over node-failure tolerance.

---

# Observability

The observability stack is:

```text
Metrics -> Prometheus -> Grafana
Logs    -> Alloy -> Loki -> Grafana
Events  -> Alloy -> Loki
Network -> Cilium / Hubble
```

Loki uses a deliberately small label set based on namespace, pod and container to limit stream cardinality.

---

# Security model

The platform combines several layers:

- UEFI Secure Boot.
- LUKS2 encrypted node disks.
- TPM2-backed automatic root unlock.
- recovery LUKS passphrase retained separately.
- SSH key authentication with password SSH disabled.
- Ansible Vault for provisioning secrets.
- Kubernetes Secret encryption in the k3s datastore.
- no inbound application port-forwarding on the home router.
- Cloudflare Zero Trust for public application access.
- Tailscale for private infrastructure administration.

TPM auto-unlock is primarily an availability/security trade-off: it keeps encrypted nodes capable of unattended reboot while preserving a separate recovery passphrase.

---

# Core stack

| Area | Technology |
|---|---|
| Bare-metal automation | Ansible, Wake-on-LAN, PXE, dnsmasq, nginx |
| Operating system | Ubuntu Server |
| Kubernetes | k3s |
| HA API | kube-vip |
| Networking | Cilium / eBPF |
| Network observability | Hubble |
| GitOps | Argo CD |
| Ingress | Traefik |
| Public edge | Cloudflare Tunnel |
| Administrative access | Tailscale |
| Certificates | cert-manager |
| Persistent storage | Longhorn |
| Databases | CloudNativePG, ClickHouse |
| Metrics | Prometheus |
| Logs | Loki + Alloy |
| Dashboards | Grafana |

---

# Repository model

The GitOps root ApplicationSet discovers workloads from:

```text
system/
platform/
apps/
```

`system/` contains foundational cluster services such as Argo CD and ingress components.

`platform/` contains shared platform capabilities such as storage, observability and databases.

`apps/` contains user-facing applications.

The detailed bare-metal and cluster bootstrap configuration lives outside the GitOps lifecycle and is executed from the management workstation before Argo CD takes ownership of Kubernetes resources.

---

# Ansible

Ansible is used to automate the bare-metal provisioning and Kubernetes bootstrap process.

The automation is split into two main stages:

1. provision the physical nodes and install Ubuntu;
2. configure the nodes and build the k3s cluster.

The provisioning workflow handles Wake-on-LAN, PXE boot, Ubuntu Autoinstall, static networking, disk encryption and SSH access. Once the nodes are reachable on their permanent IP addresses, the cluster playbook installs and configures k3s, kube-vip and Cilium.

---

## Install Ansible dependencies

```bash
ansible-galaxy collection install -r requirements.yml
```

Installs the Ansible collections required by the playbooks.

---

## Check the inventory

```bash
# copy inventory and customize to fit your setup
cp metal/inventories/prod.yml.example metal/inventories/prod.yml

ansible-inventory -i metal/inventories/prod.yml  --graph
```

Shows the hosts and groups Ansible can see before running any playbooks.

The inventory contains the three Kubernetes nodes:

```text
@all:
  |--@ungrouped:
  |--@metal:
  |  |--onyi
  |  |--mimir
  |  |--thor
  |--@masters:
  |  |--onyi
  |  |--thor
  |  |--mimir

```

---

## Test connectivity

```bash
ansible all -i metal/inventories/prod.yml -m ping
```

Checks that Ansible can connect to the installed nodes over SSH and execute commands.

This is an Ansible connectivity test.

---

## Bare-metal provisioning

Run the provisioning playbook:

```bash
ansible-playbook -i metal/inventories/prod.yml --ask-vault-pass --ask-become-pass
```

Replace `<provisioning-playbook>.yml` with the actual provisioning playbook name.

The provisioning workflow performs:

```mermaid
flowchart TB
    START["1. Start PXE containers"]
    WOL["2. Send Wake-on-LAN packet"]
    PXE["3. Machine boots through PXE"]
    INSTALL["4. Ubuntu installs"]
    SSH["5. Wait for SSH on static IP"]
    STOP["6. Remove PXE containers"]

    START --> WOL
    WOL --> PXE
    PXE --> INSTALL
    INSTALL --> SSH
    SSH --> STOP
```

The PXE services run from the management workstation at `10.0.0.52` and are only started during provisioning.

Each node receives its machine-specific configuration based on its MAC address.

---

## Kubernetes cluster bootstrap

Once all nodes are installed and reachable over SSH, run:

```bash
ansible-playbook cluster.yml --ask-vault-pass --ask-become-pass
```

The first server creates the cluster using `cluster-init`.

The remaining two servers then join using the shared k3s token.

kube-vip provides the Kubernetes control-plane endpoint:

```text
https://10.0.0.200:6443
```

Cilium is installed after the control plane is available and provides:

- Pod networking;
- eBPF Service load balancing;
- kube-proxy replacement;
- LoadBalancer IP allocation;
- Layer-2 announcements;
- Hubble network observability.

---



## Run against a single node

A playbook can be limited to one node:

```bash
ansible-playbook cluster.yml --limit mimir --ask-vault-pass --ask-become-pass
```

The same can be done for `onyi` or `thor`.

This is useful for node-specific maintenance or troubleshooting.

Use `--limit` only with tasks that are safe to run against a subset of the cluster.

---

## Check playbook syntax

```bash
ansible-playbook  cluster.yml --syntax-check
```

Checks the playbook for syntax errors without making any changes.

---

## Preview changes

```bash
ansible-playbook cluster.yml --check --ask-vault-pass --ask-become-pass
```

Runs Ansible in check mode and shows what it expects to change without applying most changes.

> Some provisioning, container and Kubernetes modules do not fully support check mode, so this should not be treated as a complete simulation.

---

## Run with additional debugging output

```bash
ansible-playbook  cluster.yml --ask-vault-pass -vv
```

Runs the playbook with more detailed output for troubleshooting.

Available verbosity levels are:

```text
-v
-vv
-vvv
-vvvv
```

For normal troubleshooting, `-vv` is usually enough.

---
## Acknowledgements

Inspired by [khuedoan/homelab](https://github.com/khuedoan/homelab).