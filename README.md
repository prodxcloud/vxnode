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
> **To stand up one or many nodes:** clone this repo, list your VM(s) in
> [`tenant.yaml`](./tenant.yaml) (or [`tenant.json`](./tenant.json)), and run
> [`setup.sh`](./setup.sh) — on the VM itself, or from your laptop over SSH.

## 📋 Contents
- [🚀 Quick start — one command](#-quick-start--one-command)
- [⚙️ Configure your nodes — `tenant.yaml` / `tenant.json`](#️-configure-your-nodes--tenantyaml--tenantjson)
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

Everything is driven by **[`setup.sh`](./setup.sh)**, which reads your VM list
from **[`tenant.yaml`](./tenant.yaml)** (or `tenant.json`). Clone, list your
VM(s), run. It installs prerequisites and deploys the node on **every** instance.

```bash
git clone https://github.com/prodxcloud/vxnode.git
cd vxnode
nano tenant.yaml         # list your VM(s) — see "Configure your nodes" below
chmod +x setup.sh
./setup.sh               # installs EVERY instance in tenant.yaml
```

For **each** instance in the file, `setup.sh` runs, in order:

1. **`tenant_prerequisites.sh`** — Docker, Docker Compose, system packages, Python, networking tools.
2. **`tenant_setup.sh`** — pulls the image, runs the container, configures Nginx, firewall, auto-update, and installs dev tools (incl. **vxcli**) inside the container.

> 💡 **You only ever edit `tenant.yaml` (or `tenant.json`).** `setup.sh` itself
> needs no editing — it's the source of truth for *which* VMs get a node.

Handy flags:
```bash
./setup.sh --list                                   # show the resolved VM list, then exit (no install)
./setup.sh --only 778ipdnsloadbalancraddress001391  # install just one instance (by name)
./setup.sh --stage prereq                           # Docker/packages only — never touches a running node
./setup.sh --stage setup                            # (re)deploy the node only — skip prerequisites
./setup.sh --stage ide                              # add the OpenVSCode IDE only — does NOT touch a running node
./setup.sh tenant.json                              # force the JSON file instead of the YAML
```

> 💻 **Browser IDE (OpenVSCode) is part of `setup.sh`.** With `install_ide: true`
> in `defaults`, the `all` stage installs it after the node; `--stage ide` adds it
> to an already-running node. It runs as a **separate** `openvscode-server`
> container (Nginx proxies `:8443` → it) and **never recreates `vxcloud-vxnode`**.
> `setup.sh` passes `connection_token` to the installer, so the IDE is reachable
> at `https://<domain>:8443/?tkn=<connection_token>`. OpenClaw stays admin-run
> (it needs provider auth) — see [Optional add-ons](#-optional-add-ons-agents-ide).

---

## ⚙️ Configure your nodes — `tenant.yaml` / `tenant.json`

`setup.sh` is **config-driven**: it reads the list of VMs from a config file and
installs the node on **every** one. You never edit `setup.sh` — you edit the
config. Two equivalent files ship in the repo root:

- **[`tenant.yaml`](./tenant.yaml)** — the **source of truth** (human-friendly, commented).
- **[`tenant.json`](./tenant.json)** — an **exact mirror**, used automatically only
  if the machine running `setup.sh` has no YAML parser (`python3` + PyYAML).
  Keep both in sync, or just keep `tenant.yaml` and regenerate the JSON.

> `setup.sh` picks the file in this order: an explicit arg (`./setup.sh tenant.json`)
> → `tenant.yaml` → `tenant.yml` → `tenant.json`. If PyYAML is missing it falls
> back to `tenant.json` on its own.

### The real shipped `tenant.yaml`

```yaml
defaults:
  email: joelwembo@outlook.com        # Let's Encrypt SSL contact (shared)
  ssh_port: 22
  docker_username: vxcloud            # image-pull user (demo)
  docker_pat: ""                      # set ONLY if vxcloud/vxnode is private
  app_port: 8744                      # vxnode API port
  connection_token: 99xctdev987654321098765   # browser IDE token (openvscode)

instances:
  # ── Instance 1 — AWS ──────────────────────────────────────────────────────
  - name: 778ipdnsloadbalancraddress001391
    ssh_host: 44.204.30.45                                    # public IP (reliable for SSH)
    ssh_user: ubuntu
    ssh_key: ./files/cloudagentkey.pem
    domain: 778ipdnsloadbalancraddress001391.vxcloud.click    # FQDN for nginx + SSL

  # ── Instance 2 — AWS ──────────────────────────────────────────────────────
  - name: 44hynewinstance96594e8c888811112
    ssh_host: 54.197.152.129
    ssh_user: ubuntu
    ssh_key: ./files/cloudagentkey.pem
    domain: 44hynewinstance96594e8c888811112.vxcloud.click
```

The **same** config as `tenant.json` (used only when PyYAML is unavailable):

```json
{
  "defaults": {
    "email": "joelwembo@outlook.com",
    "ssh_port": 22,
    "docker_username": "vxcloud",
    "docker_pat": "",
    "app_port": 8744,
    "connection_token": "99xctdev987654321098765"
  },
  "instances": [
    {
      "name": "778ipdnsloadbalancraddress001391",
      "ssh_host": "44.204.30.45",
      "ssh_user": "ubuntu",
      "ssh_key": "./files/cloudagentkey.pem",
      "domain": "778ipdnsloadbalancraddress001391.vxcloud.click"
    },
    {
      "name": "44hynewinstance96594e8c888811112",
      "ssh_host": "54.197.152.129",
      "ssh_user": "ubuntu",
      "ssh_key": "./files/cloudagentkey.pem",
      "domain": "44hynewinstance96594e8c888811112.vxcloud.click"
    }
  ]
}
```

### How `defaults` + `instances` work

`defaults` apply to **every** instance. Any key set on an individual instance
**overrides** the default for that instance only. So you set shared things
(email, ports, Docker creds, IDE token) once in `defaults`, and only the
per-VM differences (`name`, `ssh_host`, `ssh_key`, `domain`) on each instance.

#### `defaults` keys

| Key | Example | Meaning |
|---|---|---|
| `email` | `joelwembo@outlook.com` | Let's Encrypt contact for the SSL cert (shared across nodes). |
| `ssh_port` | `22` | SSH port for every VM (override per-instance if one differs). |
| `docker_username` | `vxcloud` | Docker Hub user used to pull the private `vxcloud/vxnode` image. |
| `docker_pat` | `""` | Docker Hub access token — **only** needed if the image is private. Leave `""` for public/cached. |
| `app_port` | `8744` | Port the node's API binds to (`127.0.0.1:8744` inside the VM; Nginx fronts it). |
| `connection_token` | `99xctdev987654321098765` | Browser-IDE token. `setup.sh` passes it to the IDE installer as `CONNECTION_TOKEN`. Reachable at `https://<domain>:8443/?tkn=<token>`. |
| `install_ide` | `true` | When `true`, the `all` stage also installs the OpenVSCode IDE (a **separate** container; never recreates the node). `--stage ide` does the same on demand. OpenClaw stays admin-run. |

#### `instances` keys (per VM)

| Key | Example | Meaning |
|---|---|---|
| `name` | `778ipdnsloadbalancraddress001391` | A unique label for the node. Used by `--only NAME` and in the run summary. |
| `ssh_host` | `44.204.30.45` | The VM's public IP or hostname. **Leave blank to install on THIS machine** (local — no SSH). |
| `ssh_user` | `ubuntu` | SSH login user (`ubuntu` on most clouds, `root` on bare VPS, `azureuser` on some Azure images). |
| `ssh_key` | `./files/cloudagentkey.pem` | Path to the private key. Relative paths resolve against the repo root → put keys in [`files/`](./files/). |
| `ssh_password` | *(omit)* | Use **instead of** `ssh_key` for password auth — needs [`sshpass`](#password-auth-needs-sshpass) on the machine running `setup.sh`. |
| `domain` | `778ipdnsloadbalancraddress001391.vxcloud.click` | FQDN for Nginx + the Let's Encrypt cert. Its DNS **A-record must point at `ssh_host`** before SSL can be issued. |
| `email`, `ssh_port`, `app_port`, … | *(inherited)* | Any `defaults` key can be repeated on an instance to override it just for that VM. |

> ⚠️ **SSH keys are not committed.** The config references `./files/cloudagentkey.pem`,
> but a `files/` directory holding the actual `.pem` is **not** in this repo — drop
> your key(s) there yourself, `chmod 600`, before running. The two example
> instances both share one key (`cloudagentkey.pem`); give each VM its own key by
> setting a different `ssh_key` on each instance if you prefer.

#### Add, remove, or target instances

```bash
# Add a third VM: copy an instances: block, change name/ssh_host/ssh_key/domain.
./setup.sh --list                                   # dry-run: print what WILL be installed
./setup.sh                                           # install ALL instances
./setup.sh --only 44hynewinstance96594e8c888811112   # install just one (by name)
./setup.sh --only 778...001391,44hy...11112          # install a comma-separated subset
```

#### Password auth needs `sshpass`
If an instance uses `ssh_password` instead of `ssh_key`, install `sshpass` on the
machine that runs `setup.sh`:
```bash
sudo apt-get install -y sshpass            # Ubuntu / Debian / WSL
brew install hudochenkov/sshpass/sshpass   # macOS
```
On Git Bash for Windows (no `sshpass`), use `ssh_key` instead.

---

## 🖥️ Local vs. remote install

`setup.sh` works the same in both modes — the only difference is whether an
instance's `ssh_host` is set.

**Install on a remote VM** (run from your laptop) — `ssh_host` is filled in:
```yaml
instances:
  - name: node1
    ssh_host: 44.204.30.45                 # the VM
    ssh_user: ubuntu
    ssh_key: ./files/cloudagentkey.pem      # or ssh_password: "•••••"
    domain: node1.vxcloud.click
```
`setup.sh` SSHes in, `tar`-streams this whole repo to `/tmp/vxnode-install` on
the VM, then runs prerequisites → setup there.

**Install on this machine** (run directly on the VM) — leave `ssh_host` blank:
```yaml
instances:
  - name: this-box
    ssh_host:                               # empty = local, no SSH
    domain: node1.vxcloud.click
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
setup.sh                        # ⭐ START HERE — reads tenant.yaml, orchestrates the two below for every VM.
tenant.yaml                     # ⭐ EDIT THIS — your VM list (defaults + instances). Source of truth.
tenant.json                     # exact mirror of tenant.yaml — fallback when PyYAML isn't available
files/                          # put your SSH private keys here (e.g. cloudagentkey.pem) — NOT committed
tenant_prerequisites.sh         # host prep: docker, compose, packages, python, networking
tenant_setup.sh                 # deploy: pull image, run container, nginx, ssl, firewall, in-container tools
_remote_stage_runner.sh         # internal: runs each remote stage so a backgrounded process can't hang ssh
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
| **3 · SSL** *(optional)* | If the instance's `domain` (+ `defaults.email`) is set: Let's Encrypt cert via Certbot + auto-renewal. Skipped/best-effort otherwise — the node still serves on `http://127.0.0.1:8744`. |
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
**Browser IDE (OpenVSCode)** — **preferred path is via `setup.sh`** (config-driven):
```bash
./setup.sh --stage ide                 # add the IDE to every node, node container untouched
./setup.sh --stage ide --only <name>   # just one node
```
With `install_ide: true` in `defaults`, the `all` stage installs it automatically.
It runs as a **separate** `openvscode-server` container (Nginx proxies `:8443` → it)
and **never recreates `vxcloud-vxnode`**. Open it at
`https://<domain>:8443/?tkn=<connection_token>` (no token → `403`; with token → the editor).

Running the installer **by hand on the VM** is still supported (e.g. for `code-server`):
```bash
sudo CONNECTION_TOKEN=99xctdev987654321098765 bash tenant_codebase/openvscode-server-one-time-installer.sh
# or
sudo bash tenant_codebase/code-server-one-time-installer.sh
```
The token resolves as: **(1)** `CONNECTION_TOKEN=…` env override → **(2)**
`defaults.connection_token` from a sibling `tenant.yaml`/`tenant.json` → **(3)** a
built-in fallback. Since `setup.sh` excludes `tenant.yaml` from the VM bundle, it
passes `CONNECTION_TOKEN` for you; pass it yourself only for a manual install.

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
sudo cp /path/to/.env.tenant .env                  # required: compose mounts ./.env so synced creds persist across recreate/update
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
Copy-Item .\.env.tenant "$DeployDir\.env"          # required: compose mounts ./.env so synced creds persist
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

# Summary of deployment
Successfully deployed certificate for 44hynewinstance96594e8c888811112.vxcloud.click to /etc/nginx/sites-enabled/vxcloud-tenant
Congratulations! You have successfully enabled HTTPS on https://44hynewinstance96594e8c888811112.vxcloud.click

- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
If you like Certbot, please consider supporting our work by:
 * Donating to ISRG / Let's Encrypt:   https://letsencrypt.org/donate
 * Donating to EFF:                    https://eff.org/donate-le
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
[OK] SSL certificate obtained and installed
[OK] IDE Nginx enabled: https://44hynewinstance96594e8c888811112.vxcloud.click:8443 -> http://127.0.0.1:8089
[OK] OpenClaw Nginx enabled: https://44hynewinstance96594e8c888811112.vxcloud.click:18789 -> http://127.0.0.1:18790
[INFO] Setting up SSL auto-renewal...
[OK] Certbot auto-renewal timer is active

- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
Processing
/etc/letsencrypt/renewal/44hynewinstance96594e8c888811112.vxcloud.click.conf
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

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
| `SSH connection failed` | Check the instance's `ssh_host` / `ssh_user` / `ssh_port` in `tenant.yaml`, that port `22` is open in the VM firewall, and that the key/password is right. `./setup.sh --list` prints exactly what was resolved. |
| `UNPROTECTED PRIVATE KEY FILE` / key ignored | Running from a Windows drive under WSL (`/mnt/c`), where `chmod 600` can't stick. **`setup.sh` handles this automatically** — it uses a private `0600` copy of the key and logs `using a private 0600 copy`. If you `ssh` by hand, copy the key to `~` and `chmod 600` first. |
| `ssh_key not found: ./files/…` | The `.pem` referenced in `tenant.yaml` isn't in `files/`. Drop your key there and `chmod 600` it. |
| `sshpass not installed` | `sudo apt-get install -y sshpass` (or switch the instance to `ssh_key`). |
| `no matching instances in tenant.yaml` | Your `--only NAME` doesn't match any instance `name`. Run `./setup.sh --list` to see the names. |
| `pull access denied` / image won't pull | `vxcloud/vxnode` is **private** — set `defaults.docker_pat` to a valid Docker Hub token. |
| `PyYAML unavailable` | `setup.sh` auto-falls back to `tenant.json` — make sure it mirrors `tenant.yaml`. Or `pip install pyyaml`. |
| `no matching manifest for linux/arm64` | Transient single-arch `:latest`; `tenant_setup.sh` auto-recovers via the multi-arch fallback digest. Re-run if needed. |
| Run "hangs" at 100% after a node is healthy | Older `setup.sh` could hang when the auto-update unit fired mid-install and held the SSH channel. Fixed: each remote stage runs via `_remote_stage_runner.sh` (output streamed from a VM-local file), so `ssh` always returns. |
| Only the first instance installed | Fixed: the driver loop reads the VM list on a separate file descriptor so `ssh` can't swallow the remaining instances. |
| Container not healthy | `docker logs vxcloud-vxnode --tail 50`, then `docker rm -f vxcloud-vxnode && ./setup.sh`. |
| Missing apt/apk packages | `sudo bash tenant_setup_fix_missing_packages.sh`. |
| SSL failed | Ensure the instance's `domain` DNS A-record points at its `ssh_host` and `80`/`443` are open, then re-run; or skip SSL and use the node over `127.0.0.1:8744`. |
| IDE shows `403 Forbidden` | The `?tkn=` in the URL must match `defaults.connection_token` in `tenant.yaml` (the token the installer used). |

> 🔒 **Never shipped to tenant VMs:** `setup.sh` excludes `files/` (your SSH keys
> + cloud creds) and `tenant.yaml`/`tenant.json` (the fleet inventory incl. the
> Docker PAT) from the bundle it copies to each VM — only the install scripts go.

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
