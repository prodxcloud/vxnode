# vxcloud/vxnode

**The runtime node for the [vxcloud](https://vxcloud.io) platform** — one hardened
container that provisions multi-cloud infrastructure, deploys applications, and
runs governed AI agents on your own VM.

![Docker Pulls](https://img.shields.io/docker/pulls/vxcloud/vxnode?logo=docker&label=pulls&color=2496ED)
![Image Size](https://img.shields.io/docker/image-size/vxcloud/vxnode/latest?logo=docker&label=size&color=2496ED)
![Arch](https://img.shields.io/badge/arch-amd64%20%7C%20arm64-555?logo=linux&logoColor=white)
![License](https://img.shields.io/badge/license-proprietary-lightgrey)

---

## ℹ️ Image info

| Attribute | Details |
|---|---|
| **Docker image** | `vxcloud/vxnode:latest` |
| **Publisher** | PRODXCLOUD |
| **Tooling & source** | [github.com/prodxcloud/vxnode](https://github.com/prodxcloud/vxnode) |
| **Architectures** | `linux/amd64`, `linux/arm64` (AWS Graviton · Azure Ampere) |
| **Exposed port** | `8744` — HTTP API |
| **Health check** | `GET /api/v2/health` |
| **Requires** | a vxcloud account (tenant credentials) |
| **Docs** | [vxcloud.io/docs](https://vxcloud.io/docs) |
| **License** | Proprietary © PRODXCLOUD |

> ⚠️ **Needs your account credentials.** This is the execution node for the vxcloud
> control plane — it serves its API immediately but stays **inert until you supply
> tenant credentials** (issued when you create a node). **Get started at
> [prodxcloud.com](https://prodxcloud.com).**

## ⚡ What it does

- ☁️ **Multi-cloud provisioning** — AWS, Azure, Google Cloud, Linode, DigitalOcean — Terraform-native IaC
- 🚢 **App & container deployment** — 14+ language stacks and Docker workloads over SSH, one-command HTTPS
- 🤖 **Agentic DevOps** — policy-governed AI agents (Anthropic, OpenAI, Google Gemini)
- 🔧 **One unified API** — CI/CD, networking, managed databases, storage, serverless, Kubernetes

## 🐳 Run the container

Create a `.env` with the tenant credentials from your vxcloud account (names only — values are issued to you):

```bash
# .env
VAULT_ADDR=https://vault.vxcloud.com
VAULT_ROLE_ID=<your-approle-role-id>
VAULT_SECRET_ID=<your-approle-secret-id>
TENANT_ORGANIZATION=<your-org>
TENANT_WORKSPACE=<your-workspace>
GIN_MODE=release
PORT=8744
```

**docker run**
```bash
docker run -d --name vxcloud-vxnode \
  --env-file .env \
  -p 8744:8744 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --restart unless-stopped \
  vxcloud/vxnode:latest

curl http://localhost:8744/api/v2/health      # -> {"status":"ok", ...}
```

**docker-compose.yml**
```yaml
services:
  vxnode:
    image: vxcloud/vxnode:latest
    container_name: vxcloud-vxnode
    restart: unless-stopped
    env_file: .env
    environment:
      - GIN_MODE=release
      - PORT=8744
    ports:
      - "8744:8744"            # use "127.0.0.1:8744:8744" if fronting with Nginx/TLS
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./generated:/app/generated
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8744/api/v2/health"]
      interval: 15s
      timeout: 5s
      retries: 3
    security_opt:
      - no-new-privileges:true
    cap_drop: [ALL]
    cap_add:  [NET_BIND_SERVICE]
```
```bash
docker compose up -d
```

> TLS is terminated by **Nginx + Let's Encrypt on the host**, not inside the container.
> Full provisioning, reverse-proxy, and fleet auto-update tooling:
> [github.com/prodxcloud/vxnode](https://github.com/prodxcloud/vxnode).

## 🎮 Drive it from your machine

**CLI**
```bash
curl -fsSL https://vxcloud.io/download/cli/install.sh | sh   # macOS / Linux
irm https://vxcloud.io/download/cli/install.ps1 | iex         # Windows
```
**SDKs**
```bash
npm install @vxcloud/sdk                 # TypeScript / Node
pip install vxsdk                        # Python
go get github.com/prodxcloud/vxcloud     # Go
```

## 🏷️ Tags

| Tag | Description |
|---|---|
| `latest` | Current production build — multi-arch manifest (amd64 + arm64) |
| `self-hosted` | Alias of the latest multi-arch manifest |

---

**[vxcloud.io](https://vxcloud.io)** · [Docs](https://vxcloud.io/docs) · [CLI](https://vxcloud.io/download/cli) · [SDK](https://github.com/prodxcloud/vxcloud) · [Dashboard](https://prodxcloud.com)

© PRODXCLOUD — built for regulated, multi-cloud enterprises.
