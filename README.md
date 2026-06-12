<div align="center">

# ☁️ vxnode

### The runtime **node** for the [vxcloud](https://vxcloud.io) platform

One hardened container that provisions multi-cloud infrastructure, deploys
applications, and runs governed AI agents — on **your own VM or machine**.

[![Docker Pulls](https://img.shields.io/docker/pulls/vxcloud/vxnode?logo=docker&label=docker%20pulls&color=2496ED)](https://hub.docker.com/r/vxcloud/vxnode)
[![Image Size](https://img.shields.io/docker/image-size/vxcloud/vxnode/latest?logo=docker&label=image&color=2496ED)](https://hub.docker.com/r/vxcloud/vxnode/tags)
[![Multi-arch](https://img.shields.io/badge/arch-amd64%20%7C%20arm64-555?logo=linux&logoColor=white)](https://hub.docker.com/r/vxcloud/vxnode/tags)
[![License](https://img.shields.io/badge/tooling-Apache--2.0-blue)](./LICENSE)

[🌐 Website](https://vxcloud.io) · [📚 Docs](https://vxcloud.io/docs) · [🚀 Dashboard](https://app.vxcloud.io) · [🐳 Docker Hub](https://hub.docker.com/r/vxcloud/vxnode) · [💻 CLI](https://vxcloud.io/download/cli)

</div>

---

> [!IMPORTANT]
> **This repo holds the node's *deployment, setup & update tooling* — not the server source.**
> The vxnode server ships only as a sealed, hardened multi-arch image —
> [`vxcloud/vxnode`](https://hub.docker.com/r/vxcloud/vxnode) (`linux/amd64` + `linux/arm64`).
> **To stand up a node:** clone this repo, fill your VM credentials into [`setup.sh`](./setup.sh),
> and run it — on the VM itself, or from your laptop over SSH.

## 📋 Contents
- [🚀 Quick start — one command](#-quick-start--one-command)
- [⚙️ The `setup.sh` credentials block](#️-the-setupsh-credentials-block)
- [🖥️ Local vs. remote install](#️-local-vs-remote-install)
- [⚡ What a node does](#-what-a-node-does)
- [📁 Repository layout](#-repository-layout)
- [🧰 What `setup.sh` installs (step by step)](#-what-setupsh-installs-step-by-step)
- [🔁 Reinstall & 🔧 fix](#-reinstall--fix)
- [🧩 Optional add-ons (agents, IDE)](#-optional-add-ons-agents-ide)
- [🛠️ Manual / advanced deploy](#️-manual--advanced-deploy)
- [🌐 Public HTTPS without a public IP (tunnels)](#-public-https-without-a-public-ip-tunnels)
- [🪟 Windows](#-windows)
- [🔄 Auto-update](#-auto-update)
- [✅ Verify & 🩺 troubleshoot](#-verify--troubleshoot)
- [📦 Use a node from your machine](#-use-a-node-from-your-machine)

---

## 🚀 Quick start — one command

Everything is driven by **[`setup.sh`](./setup.sh)**. Clone, fill in your VM
credentials, run. It installs prerequisites and deploys the node for you.

```bash
git clone https://github.com/prodxcloud/vxnode.git
cd vxnode
nano setup.sh            # fill in the VM CREDENTIALS block (see next section)
chmod +x setup.sh
./setup.sh
```

`setup.sh` then runs, in order:

1. **`tenant_prerequisites.sh`** — Docker, Docker Compose, system packages, Python, networking tools.
2. **`tenant_setup.sh`** — pulls the image, runs the container, configures Nginx, firewall, auto-update, and installs dev tools (incl. **vxcli**) inside the container.

> 💡 **You only ever edit the credentials block at the top of `setup.sh`.** Nothing else.

---

## ⚙️ The `setup.sh` credentials block

```bash
# ##########################################################################
# #  FILL THIS IN  —  VM CREDENTIALS                                       #
# ##########################################################################
#   Leave SSH_HOST EMPTY  -> install on THIS machine (local).
#   Set SSH_HOST          -> install on that VM over SSH.
#   Authenticate with EITHER a password OR a key (fill whichever you use).

SSH_HOST=""        # VM public IP / hostname.    EMPTY = local install
SSH_USER="ubuntu"  # SSH username (e.g. ubuntu, root, azureuser)
SSH_PASSWORD=""    # SSH password   (needs `sshpass` on this machine)
SSH_KEY=""         # OR path to a private key (.pem)
SSH_PORT="22"      # SSH port (default 22)
```

| Field | Meaning |
|---|---|
| `SSH_HOST` | The VM's public IP or hostname. **Leave empty** to install on the machine you're running `setup.sh` from. |
| `SSH_USER` | The SSH login user (`ubuntu` on most clouds, `azureuser` on some Azure images, `root` on bare VPS). |
| `SSH_PASSWORD` | Password auth. Requires [`sshpass`](#password-auth-needs-sshpass) on the machine running `setup.sh`. |
| `SSH_KEY` | Key auth — path to a `.pem`/private key. Use **either** this **or** `SSH_PASSWORD`. |
| `SSH_PORT` | SSH port, default `22`. |

The block below it (`DOMAIN`, `EMAIL`, Docker creds) is **optional** — leave it
as-is. Set `DOMAIN`/`EMAIL` only if you want HTTPS on a real domain (see
[SSL](#-what-setupsh-installs-step-by-step)). The Docker creds are demo values.

#### Password auth needs `sshpass`
If you fill `SSH_PASSWORD`, install `sshpass` on the machine that runs `setup.sh`:
```bash
sudo apt-get install -y sshpass      # Ubuntu / Debian / WSL
brew install hudochenkov/sshpass/sshpass   # macOS
```
On Git Bash for Windows (no `sshpass`), use `SSH_KEY` instead.

---

## 🖥️ Local vs. remote install

`setup.sh` works the same in both modes — only the credentials block differs.

**Install on a remote VM** (run from your laptop):
```bash
SSH_HOST="203.0.113.10"   # the VM
SSH_USER="ubuntu"
SSH_PASSWORD="•••••"       # or SSH_KEY="~/keys/node.pem"
```
`setup.sh` SSHes in, `tar`-streams this whole repo to `/tmp/vxnode-install` on
the VM, then runs prerequisites → setup there.

**Install on this machine** (run directly on the VM):
```bash
SSH_HOST=""               # empty = local
```
`setup.sh` runs prerequisites → setup right here, no SSH.

> The VM needs outbound internet (to pull the image + packages) and, for SSL,
> ports `80`/`443` open with DNS pointing at it. Port `22` open for remote installs.

---

## ⚡ What a node does
- ☁️ **Multi-cloud provisioning** — AWS, Azure, GCP, Linode, DigitalOcean (Terraform-native IaC)
- 🚢 **App & container deployment** — language stacks and Docker workloads over SSH
- 🤖 **Agentic DevOps** — policy-governed AI agents (Anthropic, OpenAI, Google Gemini)
- 🔧 **CI/CD, networking, databases, storage, serverless** — one unified API

## 🧩 The vxcloud ecosystem

| Component | Get it | Links |
|---|---|---|
| 🐳 **vxnode** — node image *(this repo's runtime)* | `docker pull vxcloud/vxnode` | [Docker Hub](https://hub.docker.com/r/vxcloud/vxnode) · [repo](https://github.com/prodxcloud/vxnode) |
| 💻 **vxcli** — command-line + TUI | `curl -fsSL https://vxcloud.io/download/cli/install.sh \| sh` | [Download](https://vxcloud.io/download/cli) |
| 📦 **SDK · TypeScript** | `npm install @vxcloud/sdk` | [npm](https://www.npmjs.com/package/@vxcloud/sdk) |
| 🐍 **SDK · Python** | `pip install vxsdk` *(or `vxcloud`)* | [PyPI](https://pypi.org/project/vxsdk/) |
| 🐹 **SDK · Go** | `go get github.com/prodxcloud/vxcloud` | [pkg.go.dev](https://pkg.go.dev/github.com/prodxcloud/vxcloud) |

---

## 📁 Repository layout
```
setup.sh                        # ⭐ START HERE — fill VM creds, run. Orchestrates the two below.
tenant_prerequisites.sh         # host prep: docker, compose, packages, python, networking
tenant_setup.sh                 # deploy: pull image, run container, nginx, ssl, firewall, in-container tools
tenant_setup_fix_missing_packages.sh   # repair a half-finished install (missing apt/apk pkgs)

install/
  prerequisites.sh              # standalone host-prep (used by the manual flow)
  prerequisites.ps1             # Windows host-prep (Docker Desktop/WSL2 + git/jq/node/python/terraform)
  docker-compose.yml            # the node container template (self-update enabled)
  vxcli_install.sh / _macos.sh / .ps1      # install the vxcli CLI            (Linux / macOS / Windows)
  cloudflare_tunnel.sh / _macos.sh / .ps1  # expose the node via Cloudflare Tunnel  (no inbound ports)
  tailnet_funnel.sh / _macos.sh / .ps1     # expose the node via Tailscale Funnel   (no inbound ports)
channels/
  stable.json                   # desired image digest for the fleet (the "what version" pointer)
  canary.json                   # same, for a canary node to test a digest before promotion
update/
  vxnode-update.sh              # host updater: pull → recreate → health-gate → rollback
  install-updater.sh            # enable the systemd timer (run once per node)
  vxnode-update.{service,timer} # the systemd units
  windows/                      # Scheduled-Task equivalent for Windows hosts

tenant_agents/                  # OPTIONAL add-ons
  openclaw_vm_installer.sh      # OpenClaw gateway (Telegram/Discord/Slack bot front-end)
  tenant_install_ollama.sh      # local Ollama models
tenant_codebase/                # OPTIONAL browser IDEs
  code-server-one-time-installer.sh
  openvscode-server-one-time-installer.sh
  GUIDE.md

DOCKERHUB.md · LICENSE · README.md
```

---

## 🧰 What `setup.sh` installs (step by step)

`tenant_prerequisites.sh` then `tenant_setup.sh` perform, in order:

| Step | What happens |
|---|---|
| **Prerequisites** | Docker + Compose, base packages, Python, DNS/networking tools, registry auth. |
| **1 · Container** | Pulls `vxcloud/vxnode:latest` (auto-falls-back to a known multi-arch digest if `:latest` is momentarily single-arch on arm64), runs it as `vxcloud-vxnode`, bound to `127.0.0.1:8744`. |
| **2 · Nginx** | Installs and configures Nginx as a reverse proxy in front of the container. |
| **3 · SSL** *(optional)* | If `DOMAIN`/`EMAIL` are set: Let's Encrypt cert via Certbot + auto-renewal. Skipped/best-effort otherwise — the node still serves on `http://127.0.0.1:8744`. |
| **4 · Firewall** | UFW rules for `22`/`80`/`443`. |
| **5 · Auto-update** | Installs the host updater + systemd timer so the node self-maintains (see [Auto-update](#-auto-update)). |
| **6 · In-container tools** | Inside the container: Terraform, Node.js, Claude Code, Codex, Gemini, **and `vxcli`** — `vxcli` is fetched as a prebuilt binary from `https://vxcloud.io/download/cli/install.sh` (amd64/arm64, no build). |

When it finishes you'll see the health URL and:
```bash
docker exec vxcloud-vxnode vxcli version     # the CLI is live inside the container
```

---

## 🔁 Reinstall & 🔧 fix

- **Re-run is safe.** `setup.sh` / `tenant_setup.sh` are idempotent — they detect
  what's already there (container, tools, certs) and only fix what's missing.
  Just run `./setup.sh` again.
- **Repair missing packages** (a half-finished or interrupted install):
  ```bash
  sudo bash tenant_setup_fix_missing_packages.sh      # on the VM
  ```
- **Start clean:**
  ```bash
  docker rm -f vxcloud-vxnode && ./setup.sh           # recreate the container
  ```

---

## 🧩 Optional add-ons (agents, IDE)

Run these **after** the node is up (on the VM). They're independent of the core node.

**OpenClaw gateway** — chat front-end (Telegram / Discord / Slack) for the node's agents:
```bash
sudo bash tenant_agents/openclaw_vm_installer.sh --configure --telegram-token "123:ABC…"
```
**Local Ollama models:**
```bash
sudo bash tenant_agents/tenant_install_ollama.sh
```
**Browser IDE** (code-server or OpenVSCode Server) — see `tenant_codebase/GUIDE.md`:
```bash
sudo bash tenant_codebase/openvscode-server-one-time-installer.sh
# or
sudo bash tenant_codebase/code-server-one-time-installer.sh
```

---

## 🛠️ Manual / advanced deploy

Prefer to do it by hand (or integrate into your own IaC)? The pieces under
`install/`, `channels/`, and `update/` are the building blocks `setup.sh` uses.

**1 · Host prerequisites**
```bash
sudo bash install/prerequisites.sh
```
**2 · Deploy the node container**
```bash
sudo mkdir -p /opt/vxcloud/generated && cd /opt/vxcloud
sudo cp /path/to/install/docker-compose.yml .
sudo docker compose up -d
curl -fsS http://127.0.0.1:8744/api/v2/health      # expect 200
```
The container binds to `127.0.0.1:8744` only — TLS terminates on the host (Nginx).

**3 · Reverse proxy + HTTPS (Nginx + Let's Encrypt)**
```bash
sudo apt-get install -y nginx certbot python3-certbot-nginx
```
`/etc/nginx/sites-available/vxnode`:
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
```bash
sudo ln -sf /etc/nginx/sites-available/vxnode /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d node1.yourdomain.com -m you@yourdomain.com --agree-tos --redirect --non-interactive
```
**4 · Enable auto-update**
```bash
sudo bash update/install-updater.sh
```
Open `80`, `443` (and `22`) in the VM's firewall / security group.

> 💡 **No public IP, or don't want to open `80`/`443`?** Skip step 3 and expose
> the node through an outbound-only [tunnel](#-public-https-without-a-public-ip-tunnels)
> instead — managed TLS, nothing inbound.

---

## 🌐 Public HTTPS without a public IP (tunnels)

The HTTPS steps above (Nginx + Let's Encrypt) assume the VM has a **public IP,
open `80`/`443`, and a DNS record**. If it doesn't — a laptop, a home server, a
box behind NAT, or a locked-down network — expose the node through an
**outbound-only tunnel** instead. The container keeps binding to
`127.0.0.1:8744`; the tunnel agent dials *out* and the provider terminates TLS
for you. **No inbound ports, no certs to manage** — the same outbound-only model
as [auto-update](#-auto-update).

Scripts live in `install/` with Linux, macOS (`_macos.sh`), and Windows (`.ps1`)
variants. Both default to port `8744` and the tunnel/node name `vxnode`.

### Option A — Cloudflare Tunnel  *(you have a domain on Cloudflare)*
```bash
HOSTNAME=node1.yourdomain.com PORT=8744 bash install/cloudflare_tunnel.sh
# keep it up across reboots (install as a systemd service):
RUN_AS_SERVICE=1 HOSTNAME=node1.yourdomain.com bash install/cloudflare_tunnel.sh
```
**What you need & why**
- A **Cloudflare account** (free) with your domain's **zone added** — Cloudflare runs the DNS and issues/renews the TLS cert.
- The script installs `cloudflared`, opens a browser to log in, creates a `vxnode` tunnel, points your hostname's DNS at it, then runs it. Result: `https://node1.yourdomain.com` served from Cloudflare's edge while the VM has **zero open inbound ports** (works behind NAT).
- **macOS:** `bash install/cloudflare_tunnel_macos.sh` (installs `cloudflared` via Homebrew). **Windows:** `.\install\cloudflare_tunnel.ps1 -DnsHostname node1.yourdomain.com` (winget; add `-AsService` to register a Windows service).

### Option B — Tailscale Funnel  *(no domain needed)*
```bash
sudo PORT=8744 bash install/tailnet_funnel.sh
```
**What you need & why**
- A **Tailscale account** (free), with **HTTPS certificates** and the **Funnel** node attribute enabled in the [admin console](https://tailscale.com/kb/1223/funnel).
- The script installs Tailscale, joins your tailnet, and turns Funnel on. Tailscale hands you a public `https://node1.<your-tailnet>.ts.net` hostname with an auto-issued cert — **no domain, no DNS record, no inbound ports**. Fastest path to a public URL.
- **macOS:** `sudo bash install/tailnet_funnel_macos.sh` (Homebrew CLI + system daemon). **Windows:** `.\install\tailnet_funnel.ps1` (run PowerShell as Administrator).

Whichever you pick, register the resulting `https://…` hostname for the node at
[app.vxcloud.io](https://app.vxcloud.io).

---

## 🪟 Windows

Windows is supported via **Docker Desktop** with the WSL2 backend (the vxnode
image is Linux-only — the host is Windows, the container is Linux).

**1 · Prerequisites** — install [Docker Desktop for Windows](https://docs.docker.com/desktop/install/windows-install/),
enable WSL2, confirm:
```powershell
docker version           # Server: Linux engine via WSL2
docker compose version
```
**2 · Deploy the node container** (PowerShell):
```powershell
$DeployDir = "$env:ProgramData\vxcloud"
New-Item -ItemType Directory -Force -Path $DeployDir,"$DeployDir\generated" | Out-Null
Copy-Item .\install\docker-compose.yml "$DeployDir\docker-compose.yml"
cd $DeployDir
docker compose up -d
Invoke-WebRequest http://127.0.0.1:8744/api/v2/health -UseBasicParsing   # expect 200
```
**3 · Reverse proxy + HTTPS** — terminate HTTPS on the host (Nginx-in-Docker, IIS
+ ARR, or a managed front like Cloudflare / ALB / App Gateway) and proxy to
`127.0.0.1:8744`. **Easiest path on Windows** is an outbound-only
[tunnel](#-public-https-without-a-public-ip-tunnels) — no inbound ports, managed TLS:
```powershell
.\install\cloudflare_tunnel.ps1 -DnsHostname node1.yourdomain.com   # Cloudflare (needs a domain)
.\install\tailnet_funnel.ps1                                        # Tailscale Funnel (no domain)
```

**4 · Enable auto-update** (PowerShell, **as Administrator**):
```powershell
powershell -ExecutionPolicy Bypass -File .\update\windows\install-updater.ps1
# uninstall:
powershell -ExecutionPolicy Bypass -File .\update\windows\install-updater.ps1 -Uninstall
```
Registers a `SYSTEM` Scheduled Task (`vxnode-update`) every 5 min — same
health-gated pull/recreate/rollback as the Linux systemd timer. Logs:
`%ProgramData%\vxcloud\update\vxnode-update.log`.

---

## 🔄 Auto-update
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
`channels/canary.json` to validate a digest before promoting it to `stable.json`:
```bash
sudo CHANNEL_URL=https://vxcloud.io/download/vxnode/canary.json bash update/install-updater.sh
```

> **Cut a release:** push the image → copy its multi-arch manifest digest into
> `channels/stable.json` (and your CDN copy at `/download/vxnode/stable.json`) →
> nodes converge within ~5 min.

---

## ✅ Verify & 🩺 troubleshoot

**Health & version**
```bash
curl -fsS http://127.0.0.1:8744/api/v2/health        # 200 + {"status":"ok"}
curl -fsS http://127.0.0.1:8744/api/v2/version       # running digest + version
docker exec vxcloud-vxnode vxcli version             # CLI inside the container
docker ps --filter name=vxcloud-vxnode               # should be "Up … (healthy)"
```

**Common issues**

| Symptom | Fix |
|---|---|
| `SSH connection failed` | Check `SSH_HOST/USER/PORT`, that port `22` is open in the VM firewall, and that the key/password is right. |
| `sshpass not installed` | `sudo apt-get install -y sshpass` (or switch to `SSH_KEY`). |
| `no matching manifest for linux/arm64` | Transient single-arch `:latest`; `tenant_setup.sh` auto-recovers via the multi-arch fallback digest. Re-run if needed. |
| Container not healthy | `docker logs vxcloud-vxnode --tail 50`, then `docker rm -f vxcloud-vxnode && ./setup.sh`. |
| Missing apt/apk packages | `sudo bash tenant_setup_fix_missing_packages.sh`. |
| SSL failed | Ensure `DOMAIN`'s DNS A-record points at the VM and `80`/`443` are open, then re-run; or skip SSL and use the node over `127.0.0.1:8744`. |

---

## 📦 Use a node from your machine
**CLI**
```bash
curl -fsSL https://vxcloud.io/download/cli/install.sh | sh   # macOS / Linux → ~/.local/bin (no sudo)
irm https://vxcloud.io/download/cli/install.ps1 | iex         # Windows
vxcli version
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

© PRODXCLOUD — built by [Joel O. Wembo](https://github.com/joelwembo || https://www.linkedin.com/in/joelwembo/ )

</div>
