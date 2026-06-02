<div align="center">

# ☁️ vxnode

### The runtime **node** for the [vxcloud](https://vxcloud.io) platform

One hardened container that provisions multi-cloud infrastructure, deploys
applications, and runs governed AI agents — on your own VM.

[![Docker Pulls](https://img.shields.io/docker/pulls/vxcloud/vxnode?logo=docker&label=docker%20pulls&color=2496ED)](https://hub.docker.com/r/vxcloud/vxnode)
[![Image Size](https://img.shields.io/docker/image-size/vxcloud/vxnode/latest?logo=docker&label=image&color=2496ED)](https://hub.docker.com/r/vxcloud/vxnode/tags)
[![Multi-arch](https://img.shields.io/badge/arch-amd64%20%7C%20arm64-555?logo=linux&logoColor=white)](https://hub.docker.com/r/vxcloud/vxnode/tags)
[![License](https://img.shields.io/badge/tooling-Apache--2.0-blue)](./LICENSE)

[🌐 Website](https://vxcloud.io) · [📚 Docs](https://vxcloud.io/docs) · [🚀 Dashboard](https://app.vxcloud.io) · [🐳 Docker Hub](https://hub.docker.com/r/vxcloud/vxnode) · [💻 CLI](https://vxcloud.io/download/cli)

</div>

---

> [!IMPORTANT]
> **This repo holds the node's *deployment & update tooling* — not the server source.**
> The vxnode server ships only as a sealed, hardened image —
> [`vxcloud/vxnode`](https://hub.docker.com/r/vxcloud/vxnode) (multi-arch `linux/amd64` + `linux/arm64`).
> It requires a **vxcloud account** to function; it is inert standalone.

## 🧩 The vxcloud ecosystem

| Component | Get it | Links |
|---|---|---|
| 🐳 **vxnode** — node image *(this repo's runtime)* | `docker pull vxcloud/vxnode` | [Docker Hub](https://hub.docker.com/r/vxcloud/vxnode) · [repo](https://github.com/prodxcloud/vxnode) |
| 💻 **vxcli** — command-line + TUI | `curl -fsSL https://vxcloud.io/download/cli/install.sh \| sh` | [Download](https://vxcloud.io/download/cli) |
| 📦 **SDK · TypeScript** | `npm install @vxcloud/sdk` | [![npm](https://img.shields.io/npm/v/%40vxcloud%2Fsdk?logo=npm&label=%40vxcloud%2Fsdk&color=CB3837)](https://www.npmjs.com/package/@vxcloud/sdk) |
| 🐍 **SDK · Python** | `pip install vxsdk` *(or `vxcloud`)* | [![PyPI](https://img.shields.io/pypi/v/vxsdk?logo=pypi&logoColor=white&label=vxsdk&color=3776AB)](https://pypi.org/project/vxsdk/) · [vxcloud](https://pypi.org/project/vxcloud/) |
| 🐹 **SDK · Go** | `go get github.com/prodxcloud/vxcloud` | [![Go Reference](https://pkg.go.dev/badge/github.com/prodxcloud/vxcloud.svg)](https://pkg.go.dev/github.com/prodxcloud/vxcloud) · [repo](https://github.com/prodxcloud/vxcloud) |

> **Windows CLI:** `irm https://vxcloud.io/download/cli/install.ps1 | iex`

## ⚡ What a node does
- ☁️ **Multi-cloud provisioning** — AWS, Azure, GCP, Linode, DigitalOcean (Terraform-native IaC)
- 🚢 **App & container deployment** — language stacks and Docker workloads over SSH
- 🤖 **Agentic DevOps** — policy-governed AI agents (Anthropic, OpenAI, Google Gemini)
- 🔧 **CI/CD, networking, databases, storage, serverless** — one unified API

Normally a node is **provisioned and managed for you** from
[app.vxcloud.io](https://app.vxcloud.io). The steps below are the manual reference
for operators — vxcloud controls node distribution, so there is no public
one-shot installer.

## 📁 Repository layout
```
install/
  tools.sh             # one-time host prep (docker, compose, terraform, node, redis, python, jq…)
  docker-compose.yml   # the node container template (self-update enabled)
channels/
  stable.json          # desired image digest for the fleet (the "what version" pointer)
  canary.json          # same, for a canary node to test a digest before promotion
update/
  vxnode-update.sh     # host updater: pull → recreate → health-gate → rollback
  install-updater.sh   # enable the systemd timer (run once per node)
  vxnode-update.{service,timer}
```

## 🛠️ Deploy a node — step by step
On a fresh Ubuntu 22.04/24.04 VM with a DNS A record pointing at it. The image is
**public**, so no registry login is required.

**1 · Install host prerequisites**
```bash
sudo bash install/tools.sh
```

**2 · Deploy the node container**
```bash
sudo mkdir -p /opt/vxcloud/generated && cd /opt/vxcloud
sudo cp /path/to/install/docker-compose.yml .     # from this repo
sudo docker compose up -d
curl -fsS http://127.0.0.1:8744/api/v2/health      # expect 200
```
The container binds to `127.0.0.1:8744` only — TLS is terminated by Nginx on the host (next step).

**3 · Reverse proxy + HTTPS (Nginx + Let's Encrypt)**
```bash
sudo apt-get install -y nginx certbot python3-certbot-nginx
```
Create `/etc/nginx/sites-available/vxnode` (proxy your domain → the container):
```nginx
server {
    listen 80;
    server_name node1.yourdomain.com;
    location / {
        proxy_pass http://127.0.0.1:8744;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 300;
    }
}
```
Enable it and obtain the certificate:
```bash
sudo ln -sf /etc/nginx/sites-available/vxnode /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d node1.yourdomain.com -m you@yourdomain.com --agree-tos --redirect --non-interactive
```

**4 · Enable auto-update** (so the node self-maintains)
```bash
sudo bash update/install-updater.sh
```
Open ports `80`, `443` (and `22`) in the VM's firewall / security group.

## 🔄 How auto-update works
```
You push a new image  ─►  Docker Hub (vxcloud/vxnode, new hardened build)
        │
        └─►  bump "digest" in channels/stable.json   (this repo / your CDN)
                          │
   each node ◄────────────┘
     • the in-container listener polls the channel and signals a host trigger
     • update/vxnode-update.sh pulls the digest, recreates the container,
       health-checks /api/v2/health, and ROLLS BACK if it doesn't come up
```
No re-deploy, no inbound connections to your VMs. Pin one canary node to
`channels/canary.json` (`sudo CHANNEL_URL=…/canary.json bash update/install-updater.sh`)
to validate a digest before promoting it to `stable.json`.

> **Cut a release:** push the image → copy its multi-arch manifest digest into
> `channels/stable.json` (and your CDN copy at `/download/vxnode/stable.json`) →
> nodes converge within ~15 min.

## 📦 Use a node from your machine
**CLI**
```bash
curl -fsSL https://vxcloud.io/download/cli/install.sh | sh   # macOS / Linux
irm https://vxcloud.io/download/cli/install.ps1 | iex         # Windows
```
**SDKs**
```bash
npm install @vxcloud/sdk                 # TypeScript / Node
pip install vxsdk                        # Python (or: pip install vxcloud)
go get github.com/prodxcloud/vxcloud     # Go
```

---

<div align="center">

**[vxcloud.io](https://vxcloud.io)** · [Docs](https://vxcloud.io/docs) · [CLI](https://vxcloud.io/download/cli) · [SDK](https://github.com/prodxcloud/vxcloud) · [Docker Hub](https://hub.docker.com/r/vxcloud/vxnode)

© PRODXCLOUD — built by [Joel O. Wembo](https://github.com/joelwembo)

</div>
