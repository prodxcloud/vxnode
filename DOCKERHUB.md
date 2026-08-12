# vxcloud/vxnode

**The runtime node for the [vxcloud](https://vxcloud.io) platform** — one hardened
container that provisions multi-cloud infrastructure, deploys applications, runs
governed AI agents, and powers the **SalesShift** go-to-market stack on your own VM.

![Docker Pulls](https://img.shields.io/docker/pulls/vxcloud/vxnode?logo=docker&label=pulls&color=2496ED)
![Image Size](https://img.shields.io/docker/image-size/vxcloud/vxnode/latest?logo=docker&label=size&color=2496ED)
![Arch](https://img.shields.io/badge/arch-amd64%20%7C%20arm64-555?logo=linux&logoColor=white)
![License](https://img.shields.io/badge/license-proprietary-lightgrey)

---

## ℹ️ Image info

| Attribute | Details |
|---|---|
| **Docker image** | `vxcloud/vxnode:latest` |
| **Version** | `2026.8.14` — same number as `vxcli` and every SDK |
| **Publisher** | PRODXCLOUD |
| **Tooling & source** | [github.com/prodxcloud/vxnode](https://github.com/prodxcloud/vxnode) |
| **SDKs** | [github.com/prodxcloud/vxcloud](https://github.com/prodxcloud/vxcloud) |
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
- 📈 **SalesShift GTM** — prospect pool, CRM, campaigns, opportunity signals and social distribution
- 🔧 **One unified API** — CI/CD, networking, managed databases, storage, serverless, Kubernetes

## 📈 SalesShift — the GTM stack, on your node

Beyond infrastructure, this node serves **SalesShift**: the go-to-market layer of
the platform. Same API, same auth, same audit trail as everything else it runs.

| Surface | What it covers |
|---|---|
| **Prospect pool** | Search people and companies by seniority, department, headcount, geography. Addresses come back **masked** — revealing one spends quota, and you can price a batch before you spend it. |
| **Leads → CRM** | A pool row is not mailable. Save it as a lead, convert it into a Contact, then it can be emailed. |
| **Tracked email** | Sends through the org's own providers via a Go email worker — suppression gating, daily caps, warmup ramp, open/click tracking on a Kafka event stream. |
| **Campaigns** | Create, schedule, send, and pull a per-recipient report with an hourly timeline. |
| **Opportunities** | A cross-tenant signal pool scraped from real sources. Save, dismiss, or push straight into a lead. |
| **Tasks** | Goal, progress and assignee on every row. |
| **Social** | One goroutine per network — the fan-out reports a **measured** speedup, not a claimed one. |
| **Webmaster** | URL inspect, robots.txt and sitemap checks, file generation. |
| **Billing** | What the workspace pays for SalesShift: plans, subscription, seats, invoices, checkout. |

Drive it from the CLI:

```bash
vxcli salesshift leads search --seniority c_level --country AU --limit 25
vxcli salesshift leads quota
vxcli salesshift leads reveal <pool-id>
vxcli salesshift leads convert-from-pool <pool-id>… --lifecycle-stage lead
vxcli salesshift leads enrich acme.com

vxcli salesshift email send --to ada@acme.com --subject "…" --html "<p>…</p>"
vxcli salesshift campaigns report <campaign-id>
vxcli salesshift contacts list
vxcli salesshift workflows test-run <id>
vxcli salesshift sequences list

vxcli salesshift opportunities list --source hn --min-score 70
vxcli salesshift opportunities push-to-lead <id>
vxcli salesshift tasks add --title "Follow up" --goal "Book a call"
vxcli salesshift social post --content "…" && vxcli salesshift social send <post-id>
vxcli salesshift webmaster inspect https://example.com
vxcli salesshift billing plans
```

…or from any SDK:

```python
# Python
import vxsdk
ss = vxsdk.Client.load_from_vxcli().salesshift

page = ss.search_leads(filters={"seniority": ["c_level"], "country": ["AU"]}, limit=50)
ids  = [p["pool_person_id"] for p in page["results"][:10]]

print(ss.reveal_quota())              # allowance / remaining / unlimited
print(ss.preview_reveal_cost(ids))    # what this batch WOULD cost, before spending
ss.save_leads(ids)
print(vxsdk.describe_convert(ss.convert_from_pool(ids, lifecycle_stage="lead")))
```

```ts
// TypeScript
import { VxCloud } from '@vxcloud/sdk';
const c = new VxCloud({ apiKey: process.env.VX_API_KEY! });

const page = await c.leads.searchLeads({ filters: { country: ['AU'] }, limit: 50 });
const { job } = await c.social.distribute(postId);
console.log(`${job.speedup}x vs sequential`);

// Every delivery carries `simulated` — a deployment holding no social API
// credentials still returns delivery records. Surface it; never report a
// simulated post as published.
for (const d of job.deliveries) console.log(d.channel, d.simulated ? 'SIMULATED' : 'published');
```

Every quota field is **null when unlimited**, never `0` — a plain zero would read
as "no allowance", the exact opposite of what the API means.

## 🐳 Run the container

Create a `.env` with the tenant credentials from your vxcloud account (names only — values are issued to you):

```bash
# .env
VAULT_ADDR=https://vault.vxcloud.io
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
vxcli version                                                 # -> 2026.8.14
```

**SDKs** — same wire contract, same auth model, same error taxonomy in every language.

| Language | Package | Install |
|---|---|---|
| Python | [`vxsdk`](https://pypi.org/project/vxsdk/) · [`vxcloud`](https://pypi.org/project/vxcloud/) | `pip install vxsdk` |
| TypeScript / Node | [`@vxcloud/sdk`](https://www.npmjs.com/package/@vxcloud/sdk) | `npm install @vxcloud/sdk` |
| Go | [`github.com/prodxcloud/vxcloud`](https://github.com/prodxcloud/vxcloud) | `go get github.com/prodxcloud/vxcloud` |
| C++ | [`cpp/`](https://github.com/prodxcloud/vxcloud/tree/main/cpp) | CMake, or drop in two files (libcurl, C++17) |
| Java | [`java/`](https://github.com/prodxcloud/vxcloud/tree/main/java) | Maven, `io.vxcloud:vxsdk` (JDK 11+, zero deps) |

The node, the CLI and all six SDKs share one version number — `2026.8.14`.

## 🏷️ Tags

| Tag | Description |
|---|---|
| `latest` | The only published tag — current production build, multi-arch manifest (amd64 + arm64) |

One moving tag, on purpose: a second alias is one more thing that can quietly
fall behind and hand somebody a stale node. If you need a build to stay put,
pin the digest rather than trusting a tag not to move.

Pin by digest if you need a build to stay put:

```bash
docker pull vxcloud/vxnode@sha256:<digest>     # from `docker buildx imagetools inspect vxcloud/vxnode:latest`
```

## 👤 Author

Built and maintained by **Joel O. Wembo**

- 💼 LinkedIn: [linkedin.com/in/joelwembo](https://www.linkedin.com/in/joelwembo/)
- 📧 Email: [joelwembo@outlook.com](mailto:joelwembo@outlook.com)

## 🔗 Links

- 📦 PyPI: [pypi.org/project/vxcloud](https://pypi.org/project/vxcloud/) · [pypi.org/project/vxsdk](https://pypi.org/project/vxsdk/)
- 📦 npm: [npmjs.com/package/@vxcloud/sdk](https://www.npmjs.com/package/@vxcloud/sdk)
- 📖 Documentation: [vxcloud.io/docs/sdks](https://vxcloud.io/docs/sdks)
- 🛠️ Source & issues: [github.com/prodxcloud/vxcloud](https://github.com/prodxcloud/vxcloud)
- 📝 Changelog: [CHANGELOG.md](https://github.com/prodxcloud/vxcloud/blob/main/CHANGELOG.md)

---

**[vxcloud.io](https://vxcloud.io)** · [Docs](https://vxcloud.io/docs) · [CLI](https://vxcloud.io/download/cli) · [SDK](https://github.com/prodxcloud/vxcloud) · [Dashboard](https://prodxcloud.com)

© PRODXCLOUD — built for regulated, multi-cloud enterprises.
