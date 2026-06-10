# OpenVSCode Server Docker Setup Instructions

## Overview

OpenVSCode Server runs VS Code in the browser (port 8089), integrated with the Valtunox iCodebase dashboard at `http://localhost:3000/dashboard?tab=icodebase`. Users can select infrastructure sessions, view and edit Terraform files in an embedded IDE, and trigger `terraform init` + `terraform apply` deployments directly from the UI.

OpenVSCode Server is built by Gitpod and is based on the upstream VS Code codebase (microsoft/vscode). Unlike code-server (by Coder), it provides a closer-to-native VS Code experience with full compatibility with the VS Code extension API.

**v1 runbooks (Docker + devcontainers, DooD, provisioning):** see [`bin/docs/v1/README.md`](bin/docs/v1/README.md).

## Architecture

```
Frontend (localhost:3000)          Go Backend (localhost:8744)          OpenVSCode Server (localhost:8089)
┌──────────────────────┐           ┌─────────────────────┐             ┌─────────────────────┐
│  iCodebase Tab       │           │  Instanode Box       │             │  VS Code in Browser  │
│  - Session list      │──fetch──> │  - Session files     │             │  - Edit .tf files    │
│  - Embedded iframe   │──deploy─> │  - terraform reapply │             │  - Terminal access   │
│  - Deploy button     │           │  - file CRUD         │             │  - Extensions        │
│  - Session in URL    │           │                      │             │  - Claude Code CLI   │
└──────────────────────┘           └─────────────────────┘             └─────────────────────┘
                                          │                                      │
                                          └── /generated/{session_id}/ ──────────┘
                                              (shared volume mount)
```

## Prerequisites

- Docker Engine 20.10+
- Docker Compose 2.0+
- 2GB RAM minimum (4GB recommended)
- Terraform installed on the host (for Go backend execution)
- Go backend (Instanode Box) running on port 8744
- Infinity API running on port 8741

## Quick Start

### Option 0: One-Time Installer Script (Everything in One Command)

The fastest way to get a fully configured OpenVSCode Server with all extensions, AI CLI tools, and DevOps tools:

```bash
cd va_golang_infra_provisionner/shared/terraform/docker/terraform_docker_ubuntu_openvscode_server/bin
chmod +x openvscode-server-one-time-installer.sh
./openvscode-server-one-time-installer.sh
```

This script automatically:
- Creates host directories and fixes permissions
- Pulls and starts the OpenVSCode Server container (mounts host `docker.sock` when present; matches Docker-outside-of-Docker)
- Installs all VS Code extensions (Codeium, Continue.dev, Tabby, **Dev Containers**, Terraform, GitLens, etc.)
- Installs AI CLI tools (Claude Code, Gemini CLI, OpenAI Codex)
- Installs DevOps tools (Terraform, kubectl, Helm, Minikube, GitHub CLI, AWS CLI, Azure CLI)
- Installs Node.js 20 LTS, Python 3, Git, **Docker CLI + Docker Compose** (host daemon via socket)
- Verifies all installations and prints a summary

After it finishes, open `http://localhost:8089` (no password required by default).

### Option 1: Docker Compose (Manual)

```bash
cd va_golang_infra_provisionner/shared/terraform/docker/terraform_docker_ubuntu_openvscode_server/bin

# Create host directories
mkdir -p ~/openvscode-server/config ~/openvscode-server/projects ~/openvscode-server/data

# Fix permissions (UID 1000 = openvscode-server user inside container)
sudo chown -R 1000:1000 ~/openvscode-server/config ~/openvscode-server/projects ~/openvscode-server/data

# Set DOCKER_GID in .env to match the host docker socket (Linux/WSL2)
#   stat -c '%g' /var/run/docker.sock
# See bin/docs/v1/HOST_DOCKER.md

# Start
docker-compose up -d

# Bootstrap tools inside the container (extensions, Docker CLI, Python, Node, …)
chmod +x openserver-post-deploy.sh && ./openserver-post-deploy.sh
```

### Option 2: Standalone Docker Run

```bash
docker rm -f openvscode-server

docker run -d \
  --name openvscode-server \
  --restart unless-stopped \
  -p 8089:3000 \
  -e TZ=UTC \
  -v ~/openvscode-server/config:/home/openvscode-server/.config \
  -v ~/openvscode-server/projects:/home/workspace/projects \
  -v /mnt/c/Users/joelwembo/Desktop/production/va/va_golang_infra_provisionner/generated:/home/workspace/projects/generated \
  -v ~/openvscode-server/data:/home/openvscode-server/.openvscode-server \
  --cpus="2.0" \
  --memory="2g" \
  --log-driver json-file \
  --log-opt max-size=10m \
  --log-opt max-file=3 \
  gitpod/openvscode-server:latest \
  --without-connection-token --host 0.0.0.0
```

### Verify

```bash
docker ps --filter name=openvscode-server
docker logs --tail 5 openvscode-server
```

You should see: `Web UI available at http://0.0.0.0:3000` (mapped to host port 8089)

## OpenVSCode Server vs Code-Server

| Feature | OpenVSCode Server (Gitpod) | Code-Server (Coder) |
|---------|---------------------------|---------------------|
| **Base** | Upstream VS Code (microsoft/vscode) | Fork of VS Code |
| **Extension API** | Full VS Code extension API | Slightly modified API |
| **Marketplace** | Open VSX (default) | Open VSX |
| **Auth** | Connection token (or `--without-connection-token`) | Password-based |
| **Default Port** | 3000 (host: 8089) | 8080 |
| **Container User** | `openvscode-server` (UID 1000) | `coder` (UID 1000) |
| **Home Dir** | `/home/openvscode-server` | `/home/coder` |
| **Data Dir** | `/home/openvscode-server/.openvscode-server` | `/home/coder/.local/share/code-server` |
| **Image** | `gitpod/openvscode-server` | `codercom/code-server` |
| **Install Extension** | `openvscode-server --install-extension` | `code-server --install-extension` |

## Configuration

| Variable | Value | Description |
|----------|-------|-------------|
| `CONNECTION_TOKEN` | *(empty = disabled)* | Connection token for authentication |
| `TZ` | `UTC` | Container timezone |
| Port | `8089` | OpenVSCode Server web UI |
| CPU Limit | `2.0` | Max CPU cores |
| Memory Limit | `2G` | Max RAM |

### Authentication Options

OpenVSCode Server supports two auth modes:

1. **No authentication** (development): `--without-connection-token`
2. **Token-based** (production): Set `CONNECTION_TOKEN=your-secret-token` env var

To enable token auth, remove `--without-connection-token` from the docker-compose command and set:

```yaml
environment:
  - CONNECTION_TOKEN=your-secret-token-here
```

Then access via: `http://localhost:3000/?tkn=your-secret-token-here`

## Volume Mounts

| Host Path | Container Path | Purpose |
|-----------|---------------|---------|
| `~/openvscode-server/config` | `/home/openvscode-server/.config` | VS Code config |
| `~/openvscode-server/projects` | `/home/workspace/projects` | User project files |
| `.../generated` | `/home/workspace/projects/generated` | Session terraform files from Go backend |
| `~/openvscode-server/data` | `/home/openvscode-server/.openvscode-server` | All data: extensions, settings, cache, logs |
| `./config/settings.json` | `.../data/Machine/settings.json` | VS Code machine settings |
| Host `/var/run/docker.sock` | `/var/run/docker.sock` | Docker-outside-of-Docker: CLI in IDE uses host daemon (set `DOCKER_GID` in `bin/.env`) |

The `generated` volume is critical — it maps the Go backend's session storage into OpenVSCode Server so Terraform files are visible when a session is opened.

The `data` volume persists the entire OpenVSCode Server data directory (extensions, settings, workspace storage) so nothing is lost on container restart.

## Settings (config/settings.json)

```json
{
  "extensions.ignoreRecommendations": true,
  "workbench.startupEditor": "none",
  "telemetry.telemetryLevel": "off",
  "editor.fontSize": 14,
  "editor.tabSize": 2,
  "editor.minimap.enabled": false,
  "editor.wordWrap": "on",
  "files.autoSave": "afterDelay",
  "files.autoSaveDelay": 1000,
  "terminal.integrated.fontSize": 13,
  "workbench.colorTheme": "Default Dark Modern"
}
```

## Extensions

OpenVSCode Server uses the [Open VSX](https://open-vsx.org/) marketplace by default. Microsoft-exclusive extensions (GitHub Copilot, Gemini Code Assist) are **not available** directly.

### Installing Extensions

Fix permissions first, then install:

```bash
# Fix permissions (required after fresh container creation)
docker exec -u root openvscode-server chown -R openvscode-server:openvscode-server /home/openvscode-server/.openvscode-server

# AI Coding Assistants
docker exec openvscode-server openvscode-server --install-extension codeium.codeium
docker exec openvscode-server openvscode-server --install-extension Continue.continue
docker exec openvscode-server openvscode-server --install-extension TabbyML.vscode-tabby

# Languages & Infrastructure
docker exec openvscode-server openvscode-server --install-extension hashicorp.terraform
docker exec openvscode-server openvscode-server --install-extension redhat.vscode-yaml
docker exec openvscode-server openvscode-server --install-extension esbenp.prettier-vscode
docker exec openvscode-server openvscode-server --install-extension dbaeumer.vscode-eslint

# Productivity & Git
docker exec openvscode-server openvscode-server --install-extension eamodio.gitlens
docker exec openvscode-server openvscode-server --install-extension mhutchie.git-graph
docker exec openvscode-server openvscode-server --install-extension usernamehw.errorlens
docker exec openvscode-server openvscode-server --install-extension Gruntfuggly.todo-tree
docker exec openvscode-server openvscode-server --install-extension aaron-bond.better-comments

# UI & Appearance
docker exec openvscode-server openvscode-server --install-extension pkief.material-icon-theme
docker exec openvscode-server openvscode-server --install-extension zhuangtongfa.material-theme
docker exec openvscode-server openvscode-server --install-extension oderwat.indent-rainbow

# Restart to apply
docker restart openvscode-server
```

### Extension Reference

#### AI Coding Assistants

| Extension | ID | Description |
|---|---|---|
| **Codeium** | `codeium.codeium` | Free AI autocomplete + chat (closest to GitHub Copilot) |
| **Continue.dev** | `Continue.continue` | Open-source AI assistant — connect your own API keys (Claude, GPT, Gemini, Ollama) |
| **Tabby** | `TabbyML.vscode-tabby` | Self-hosted AI coding assistant with repo indexing |

#### Languages & Infrastructure

| Extension | ID | Description |
|---|---|---|
| **Terraform** | `hashicorp.terraform` | HCL syntax highlighting, validation, autocomplete |
| **YAML** | `redhat.vscode-yaml` | YAML/docker-compose support with schema validation |
| **Prettier** | `esbenp.prettier-vscode` | Auto code formatting (JS, TS, JSON, CSS, HTML) |
| **ESLint** | `dbaeumer.vscode-eslint` | JavaScript/TypeScript linting |
| **Tailwind CSS** | `bradlc.vscode-tailwindcss` | Tailwind class autocomplete and preview |

#### Productivity & Git

| Extension | ID | Description |
|---|---|---|
| **GitLens** | `eamodio.gitlens` | Git blame, history, annotations inline |
| **Git Graph** | `mhutchie.git-graph` | Visual git log and branch management |
| **Error Lens** | `usernamehw.errorlens` | Show errors/warnings inline on the line |
| **TODO Tree** | `Gruntfuggly.todo-tree` | Find and list all TODOs across the codebase |
| **Better Comments** | `aaron-bond.better-comments` | Color-coded comments (alerts, queries, TODOs) |

#### UI & Appearance

| Extension | ID | Description |
|---|---|---|
| **Material Icon Theme** | `pkief.material-icon-theme` | Beautiful file/folder icons |
| **One Dark Pro** | `zhuangtongfa.material-theme` | Popular dark theme |
| **Indent Rainbow** | `oderwat.indent-rainbow` | Colored indentation guides |

### Extensions NOT Available in OpenVSCode Server

These are locked to official VS Code and will cause errors if you try to install them:

| Extension | Reason |
|---|---|
| GitHub Copilot (`GitHub.copilot`) | Microsoft/GitHub proprietary |
| GitHub Copilot Chat (`GitHub.copilot-chat`) | Microsoft/GitHub proprietary |
| Gemini Code Assist (`Google.gemini-code-assist`) | Not published to Open VSX |

## Claude Code CLI

[Claude Code](https://www.npmjs.com/package/@anthropic-ai/claude-code) is Anthropic's AI coding assistant that runs in the terminal. It can be installed inside the OpenVSCode Server container for AI-powered coding directly in the integrated terminal.

### Installation

```bash
# Install Node.js, npm, and Claude Code CLI inside the container
docker exec -u root openvscode-server bash -c "apt-get update && apt-get install -y nodejs npm && npm install -g @anthropic-ai/claude-code"

# Verify installation
docker exec openvscode-server claude --version
```

### Authentication

Open a terminal inside OpenVSCode Server (Ctrl+\`) and run:

```bash
claude
```

This will prompt you to authenticate. You can either:
- **API Key**: Set `ANTHROPIC_API_KEY` environment variable
- **Browser Login**: Follow the OAuth flow to sign in with your Anthropic account

To set the API key permanently, add it to the docker-compose environment:

```yaml
environment:
  - ANTHROPIC_API_KEY=sk-ant-your-key-here
```

### Usage

Once authenticated, use Claude Code from any terminal inside OpenVSCode Server:

```bash
# Start interactive session
claude

# Ask a question
claude "explain this terraform configuration"

# Edit files
claude "add an S3 bucket to main.tf with versioning enabled"

# Run in a specific directory
cd /home/workspace/projects/generated/{session_id}
claude
```

## Installing DevOps Tools

kubectl, Helm, and Minikube can be installed inside the container. Fix permissions first:

```bash
# Fix all permissions under .openvscode-server (prevents EACCES errors)
docker exec -u root openvscode-server chown -R openvscode-server:openvscode-server /home/openvscode-server/.openvscode-server
docker exec -u root openvscode-server mkdir -p /home/openvscode-server/.openvscode-server/extensions
docker exec -u root openvscode-server chown -R openvscode-server:openvscode-server /home/openvscode-server/.openvscode-server

# Install kubectl
docker exec -u root openvscode-server bash -c "curl -LO 'https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl' && chmod +x kubectl && mv kubectl /usr/local/bin/"

# Install Helm
docker exec -u root openvscode-server bash -c "curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"

# Install Minikube
docker exec -u root openvscode-server bash -c "curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64 && chmod +x minikube-linux-amd64 && mv minikube-linux-amd64 /usr/local/bin/minikube"

# Verify
docker exec openvscode-server kubectl version --client
docker exec openvscode-server helm version
docker exec openvscode-server minikube version
```

> **Note:** If you get `EACCES: permission denied`, run the `chown` commands above first.

## Usage with iCodebase Dashboard

### Accessing the Dashboard

Open `http://localhost:3000/dashboard?tab=icodebase`

### URL Parameters

The session ID is reflected in the browser address bar for bookmarking and sharing:

| URL | Description |
|---|---|
| `/dashboard?tab=icodebase` | Dashboard view (session list) |
| `/dashboard?tab=icodebase&session=<id>` | Opens an editor session |
| `/dashboard?tab=icodebase&cloudSession=<id>` | Opens a cloud/terraform session in OpenVSCode Server |

Refreshing the page preserves the active session. Sharing the URL opens that session directly.

### Session Workflow

1. **Your Sessions** table shows all cloud operations fetched from the Infinity API
2. Click **Run** on any session row to open it in the embedded OpenVSCode Server iframe
3. OpenVSCode Server loads the session folder at `/home/workspace/projects/generated/{session_id}`
4. Edit Terraform files (`main.tf`, `variables.tf`, `providers.tf`, etc.) directly in the browser
5. Use Claude Code in the terminal for AI-assisted editing

### Deploying Infrastructure

1. Open a session in the editor view
2. Click the green **Deploy** button in the toolbar
3. The deploy modal shows:
   - Session ID
   - Cloud provider (AWS, Azure, etc.)
   - Resource type (vm, docker, container, etc.)
4. Click **Deploy Now**
5. This triggers `terraform init` + `terraform apply` via the Go backend (`POST /api/v2/tenant/session/terraform/reapply`)
6. Terraform output (init + apply) is displayed in the modal
7. Green check = success, red alert = failure with error output

### Switching Sessions

Click the **Switch** button in the header bar to open the session switcher dropdown. It shows:

- **Cloud Sessions** — all Terraform/infrastructure sessions with status, provider, and session ID
- **Editor Sessions** — local editor sessions
- **Back to Dashboard** — return to the full dashboard view

The currently active session is highlighted. Click any session to switch instantly.

### Toolbar Buttons

| Button | Action |
|--------|--------|
| **Deploy** | Opens the terraform deploy modal |
| **Sync** | Re-fetches session files from Go backend and reloads the iframe |
| **New Tab** | Opens OpenVSCode Server in a separate browser tab |
| **Fullscreen** | Enters/exits fullscreen mode |

### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| **F11** | Toggle fullscreen mode |
| **Escape** | Exit fullscreen mode |

### Launch Environment Options

| Option | Action |
|--------|--------|
| **Va Desktop** | Opens via VS Code Desktop protocol handler |
| **Vs Code Web (OpenVSCode Server)** | Opens embedded OpenVSCode Server iframe (port 3000) |
| **ValtunoxCLI** | Opens embedded editor with CLI tools |

## Management Commands

```bash
# Start
docker-compose up -d

# Stop
docker-compose down

# Restart
docker restart openvscode-server

# View logs
docker logs -f openvscode-server

# Check resource usage
docker stats openvscode-server --no-stream

# Inspect volumes
docker inspect -f '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}' openvscode-server

# Update image
docker-compose pull && docker-compose up -d

# Shell into the container
docker exec -it openvscode-server bash

# Shell as root (for installing packages)
docker exec -u root -it openvscode-server bash
```

## Troubleshooting

### Container in restart loop (EACCES permission denied)

```bash
sudo chown -R 1000:1000 ~/openvscode-server/config ~/openvscode-server/projects ~/openvscode-server/data
docker restart openvscode-server
```

### Extension or tool install fails with permission denied (EACCES)

This happens when `/home/openvscode-server/.openvscode-server` is owned by root. Fix all permissions at once:

```bash
docker exec -u root openvscode-server chown -R openvscode-server:openvscode-server /home/openvscode-server/.openvscode-server
docker restart openvscode-server
```

### Session folder empty in OpenVSCode Server

The `generated` volume is not mounted. Recreate the container with the `-v .../generated:/home/workspace/projects/generated` mount.

### Port 8089 already in use

```bash
# Find what's using it
lsof -i :8089
# Or force remove and recreate
docker rm -f openvscode-server
```

### Deploy button shows "Deployment Failed"

- Verify Go backend is running: `curl http://localhost:8744/health`
- Check session exists: `curl "http://localhost:8744/api/v2/tenant/session/files/all?username=<user>&session_id=<id>"`
- Check terraform is installed in the Go backend environment

### Can't access OpenVSCode Server UI

```bash
docker ps --filter name=openvscode-server
docker logs --tail 20 openvscode-server
netstat -tlnp | grep 8089
```

### Claude Code CLI not found

```bash
docker exec -u root openvscode-server bash -c "apt-get update && apt-get install -y nodejs npm && npm install -g @anthropic-ai/claude-code"
docker restart openvscode-server
```

## API Endpoints Used

| Endpoint | Backend | Purpose |
|----------|---------|---------|
| `GET /api/v3/provisioner/cloud/operations` | Infinity (8741) | List user sessions |
| `GET /api/v2/tenant/session/files/all` | Go (8744) | Fetch session files |
| `POST /api/v2/tenant/session/terraform/reapply` | Go (8744) | Run terraform init + apply |
| `POST /api/v2/tenant/session/file` | Go (8744) | Create/update a file |

## Resources

- OpenVSCode Server: https://github.com/gitpod-io/openvscode-server
- Gitpod: https://www.gitpod.io/
- Open VSX Marketplace: https://open-vsx.org/
- Claude Code: https://www.npmjs.com/package/@anthropic-ai/claude-code
- Continue.dev: https://continue.dev/
- Codeium: https://codeium.com/
- Terraform: https://www.terraform.io/

---

## AI Coding Assistants for OpenVSCode Server

OpenVSCode Server uses the Open VSX marketplace (not Microsoft's), so not all AI extensions are available directly. Below are the tested and recommended options.

### Option 1: GitHub Copilot (Community Installer)

A community installer script handles download and installation of GitHub Copilot for OpenVSCode Server:

```bash
# Inside the openvscode-server container
docker exec openvscode-server bash -c \
  "curl -fsSL https://raw.githubusercontent.com/sunpix/howto-install-copilot-in-code-server/refs/heads/main/install-copilot.sh | bash"
```

**Requirements:** OpenVSCode Server latest, `curl`, `jq`, active GitHub Copilot subscription ($10-19/month).

After installation, reload the browser tab and sign in with your GitHub account.

### Option 2: Kilo Code (Multi-Model AI Agent - Recommended)

Open-source AI coding agent supporting 500+ models (Gemini, Claude, GPT). Available on Open VSX.

```bash
docker exec openvscode-server openvscode-server --install-extension kilocode.Kilo-Code
```

**Features:**
- Inline autocomplete suggestions
- Agent mode (Architect, Coder, Debugger modes)
- Browser automation
- Supports Gemini 2.5 Pro, Claude, GPT-5 via your own API keys

**Setup:** After install, reload the browser tab (F5). Click the Kilo icon in the sidebar and configure your API key.

### Option 3: Continue.dev (Multi-Model Chat + Autocomplete)

Open-source extension that lets you use Gemini, Claude, or any model for both chat and inline completions.

```bash
docker exec openvscode-server openvscode-server --install-extension continue.continue
```

Then configure inside the container at `~/.continue/config.json`:

```json
{
  "models": [
    {
      "title": "Gemini 2.5 Pro",
      "provider": "google-genai",
      "model": "gemini-2.5-pro",
      "apiKey": "YOUR_GEMINI_API_KEY"
    },
    {
      "title": "Claude Sonnet",
      "provider": "anthropic",
      "model": "claude-sonnet-4-20250514",
      "apiKey": "YOUR_ANTHROPIC_API_KEY"
    }
  ],
  "tabAutocompleteModel": {
    "title": "Gemini Flash",
    "provider": "google-genai",
    "model": "gemini-2.0-flash",
    "apiKey": "YOUR_GEMINI_API_KEY"
  }
}
```

### Option 4: Codeium (Free Copilot Alternative)

Free unlimited autocomplete, no API key required (account signup only).

```bash
docker exec openvscode-server openvscode-server --install-extension codeium.codeium
```

After install, reload browser and sign up / log in via the Codeium sidebar.

### Option 5: Windsurf Extension

Works in OpenVSCode Server and provides inline completions + chat panel.

```bash
docker exec openvscode-server openvscode-server --install-extension codeium.windsurf
```

### Option 6: CLI-Based AI Tools (Already Installed)

These run in the terminal inside OpenVSCode Server:

| Tool | Command | Auth |
|------|---------|------|
| Claude Code | `claude` | `claude auth` (API key or browser) |
| Gemini CLI | `gemini` | `gemini auth` (Google account) |
| OpenAI Codex | `codex` | `OPENAI_API_KEY` env var |

### Gemini in OpenVSCode Server (Firebase Studio Approach)

Firebase Studio integrates Gemini natively as a built-in feature providing:
- Inline code completions as you type
- Chat panel with Ask mode + Agent mode (`Ctrl+Shift+Space`)
- Codebase indexing for context-aware suggestions

To replicate this in OpenVSCode Server, use **Continue.dev + Gemini API** (Option 3) which provides the closest experience, or **Kilo Code** (Option 2) which supports Gemini via API key.

### Recommended Setup for Valtunox IDE

| Feature | Tool |
|---------|------|
| Inline autocomplete | Kilo Code or Continue.dev with Gemini Flash |
| AI Chat / Agent | Kilo Code or Continue.dev with Gemini 2.5 Pro / Claude |
| Terminal AI | Claude Code CLI + Gemini CLI |
| Free backup | Codeium |

### Extensions Not Compatible with OpenVSCode Server

These require Microsoft's proprietary marketplace and will **not** install:

- `GitHub.copilot` (use the installer script workaround above)
- `GitHub.copilot-chat` (merged into copilot, use installer script)
- `Google.gemini-code-assist` (not on Open VSX, use Continue.dev instead)

### After Installing Any Extension

No container restart needed. Just:
1. Reload the browser tab (F5 or Ctrl+R)
2. Or use command palette: `Ctrl+Shift+P` > `Developer: Reload Window`

---

## In-Editor Browser Preview (Like Firebase Studio / GitHub Codespaces)

OpenVSCode Server supports an embedded browser panel for previewing web apps directly inside the editor, similar to Firebase Studio's "Web" panel and GitHub Codespaces' "Simple Browser".

### Simple Browser (Built-in, No Extension Needed)

OpenVSCode Server includes Simple Browser by default:

1. Open command palette: `Ctrl+Shift+P`
2. Type: **Simple Browser: Show**
3. Enter a URL (e.g. `http://localhost:5173`)

A browser tab opens inside the editor alongside your code.

You can also trigger it programmatically via a VS Code task:

```json
{
  "inputs": [
    {
      "id": "openPreview",
      "type": "command",
      "command": "simpleBrowser.show",
      "args": ["http://localhost:5173"]
    }
  ]
}
```

### Live Server (HTML/Static File Preview with Auto-Refresh)

For live-reloading HTML files on save:

```bash
docker exec openvscode-server openvscode-server --install-extension ritwickdey.LiveServer
```

After reload, right-click any `.html` file > **Open with Live Server**. It auto-refreshes the preview on every save.

### Port Forwarding for App Preview

Since OpenVSCode Server runs in Docker, app ports must be exposed for the preview to work. Add extra port mappings when creating the container:

```
-p 8089:3000   # OpenVSCode Server
-p 5173:5173   # Vite dev server
-p 8000:8000   # Python / Go server
-p 4200:4200   # Angular dev server
-p 8080:8080   # General purpose
```

If you need to add more ports, you must recreate the container (`docker rm -f openvscode-server` then re-run with the extra `-p` flags). Extensions and settings persist in `~/openvscode-server/data`.

Start your app inside the OpenVSCode Server terminal, then open Simple Browser to `http://localhost:<port>`.

### Preview Workflow

1. Open a terminal in OpenVSCode Server (`Ctrl+``)
2. Start your dev server (e.g. `npm run dev`)
3. `Ctrl+Shift+P` > `Simple Browser: Show` > enter `http://localhost:5173`
4. The preview panel opens side-by-side with your code
5. Edit code, save, and the preview updates (with Live Server or HMR)

### Known Limitations

- Simple Browser works best with HTTP (not HTTPS with self-signed certs)
- If accessing OpenVSCode Server through a reverse proxy, preview URLs must be routable from the container
- Live Preview (Microsoft's extension) has reported bugs in OpenVSCode Server; use Live Server (ritwickdey) instead

---
**Last Updated**: March 2026
 # Dev Container Research
 # Devcontainer workflow (Codespaces-like, v1)

## What you get

- **Outer** environment: OpenVSCode Server in Docker — editor, terminal, extensions.
- **Inner** environment: a **devcontainer** built from `.devcontainer/devcontainer.json` (Microsoft `mcr.microsoft.com/devcontainers/*` images or custom).

The Go API `HandleCreateCodespace` writes `generated/<session_id>/.devcontainer/devcontainer.json` when you create a codespace-style session. Terraform sessions may also include `.devcontainer`.

## Prerequisites inside the IDE container

1. **Dev Containers** extension installed (installer / post-deploy scripts add `ms-vscode-remote.remote-containers` when available on Open VSX).
2. **Docker CLI** + **Compose** installed (via `bin/lib/` scripts).
3. **Host** `docker.sock` mounted into the `openvscode-server` container and correct `group_add` / `DOCKER_GID`.

Then `docker ps` in the integrated terminal should work.

## User steps

1. Open folder: `/home/workspace/projects/generated/<session_id>` (or your project root).
2. Command palette: **Dev Containers: Reopen in Container** (or **Rebuild and Reopen in Container**).
3. Wait for the image build/pull; terminals and tasks run **inside** the devcontainer.

## Reference template

See `bin/devcontainer/valtunox-fullstack/` for a sample JSON with Python, Node feature, and Docker-outside-of-docker.

## Outer vs inner Python / Node

- Tools installed by the installer in the **outer** container are for the editor host.
- The **devcontainer** image brings its own Python/Node — that is expected and matches GitHub Codespaces behavior.

## If the extension does not install

Open VSX availability can change. Check [open-vsx.org](https://open-vsx.org/) for `remote-containers` and adjust the extension id in the installer scripts if needed.
