# VxCloud / SalesShift operator context

This is the safe orientation guide for Claude, OpenAI, Codex and other
automation agents working with a VxCloud node. It describes the platform; it
is not authorization to deploy, send mail, delete data, rotate credentials or
change a tenant. Use a dry-run/read-only check first and request approval for
destructive or external side effects.

## Release and repository map

The November 1, 2026 release line is CalVer **2026.11.1**. The production
tenant-node channel is `vxcloud/vxnode:latest`, build
`v2026.11.1-0527`, for `linux/amd64` and `linux/arm64`; the exact digest is in
`channels/stable.json`. Public repositories are:

- `prodxcloud/vxcloud`: Go SDK plus Python, TypeScript, C++ and Java SDKs.
- `prodxcloud/vxnode`: node deployment tooling, inventory, SSL/reverse proxy,
  update channels and repair scripts; the runtime is the sealed image.
- `prodxcloud/vxthinkingllm`: local VxThinking reasoning and specialist APIs.

Never commit API keys, provider keys, SMTP passwords, Vault tokens, SSH keys,
tenant `.env` files or secret values copied from a runbook. Use placeholders.

## What the platform does

VxCloud is a tenant-aware control plane for registration/login, organization
and workspace membership, billing and node purchases, node selection/sync,
developer keys, infrastructure, CI/CD, workflows/Mission Control, Agent
Control, chat, memory/library, settings and observability. A request resolves
the active workspace and selected node before execution; it must not cross
tenant boundaries.

Each tenant node runs the Dockerized Go runtime and VxComputer (plan,
approval, act, verify), `vxcli`, Terraform, Docker-based app deployment,
governed AI tools, health/version routes and the SalesShift worker surface.
Nginx/Cloudflare terminates HTTPS; the container normally binds privately to
port 8744. `@nodes <hostname>` targets another node owned by the same
workspace; without it, the selected default node is used.

SalesShift shares the workspace and audit model for lead enrichment (saved to
the leads table), contacts/CRM, opportunities/proposals, mail compose/reply,
sequences/campaigns, tasks/delegation, messaging, billing and reporting.
Outbound email is approval-gated by default: a draft is not a send, and a
real send must leave a delivery/audit record. Provider/model choices include
Anthropic, OpenAI, Ollama and VxThinking; record the provider and model.

## Runtime architecture

```text
Browser / vxcli / SDKs -> auth + workspace/developer-key exchange
      -> FastAPI 8741 -> Go core 8743 -> tenant node/VxComputer 8744
      -> Django/admin 8742 and PostgreSQL 5432
      -> Redis 6379 (Celery broker/results/cache) + Kafka 9092/2181 (events)
      -> Temporal 7233 (long workflows; optional UI 8233)
      -> Vault 8200 + Consul 8500 (secrets/discovery)
      -> VxThinking 8745 (optional legacy sidecar 8746) + alerts 8014
```

Celery workers consume queued jobs and Celery beat emits schedules. Kafka is
the durable event/audit path; Temporal owns long-running workflow history,
retry and cancellation. A job is complete only when its queue/event/audit
state and user-visible result agree.

## Port and hostname map

| Port | Service / purpose |
|---:|---|
| 80/443 | Nginx/Cloudflare ingress and TLS |
| 3000 | production VxCloud web container |
| 3010 | `vxcloud_web` Next.js development server |
| 3020 | SalesShift development server |
| 3021 | SalesShift production-like `npm run build && npm start` |
| 3009 / 5173 | local `vxadmin` ports (configured / Vite fallback) |
| 8741 | FastAPI API gateway/control plane (`api.vxcloud.io`) |
| 8742 | Django/admin/ORM service; normally private |
| 8743 | Go VxCloud core (`cloud.vxcloud.io`) |
| 8744 | tenant Go node and VxComputer API (`node*.vxcloud.click`) |
| 8745 | VxThinkingLLM/local reasoning service |
| 8746 | optional legacy VxThinking specialist sidecar |
| 8014 | alerts and notifications service |
| 7233 / 8233 | Temporal frontend / optional operator UI |
| 8200 / 8500 | Vault / Consul APIs; keep private |
| 9092 / 2181 | Kafka / legacy Zookeeper; internal only |
| 6379 / 5432 | Redis / PostgreSQL; private network only |
| 11434 | Ollama; private or authenticated |
| 18789 | optional OpenClaw gateway |
| 8443 / 8089 | node IDE/mailcow HTTPS context and backend |
| 5555 / 8289 | optional Celery Flower / Kafka UI |

Cloudflare deployment documentation is authoritative for public ingress. A
reachable local port is not automatically safe to publish.

## Authentication, sync and repair

After billing is active and a node is purchased, use **Sync With Workspace**
on the Nodes page. It verifies HTTPS reachability, tenant ownership and the
Vault-backed `.env`/developer-key references. Docker running alone is not
readiness; the node must pass health/version checks and appear in the correct
workspace. The CLI session is `~/.vxcloud/credentials.json` (mode 0600); SDKs
can load it or accept an `xc_live_*`, `xc_dev_*` or `xc_test_*` key.

On the VM, run read-only checks first:

```bash
docker ps --filter name=vxcloud-vxnode
curl -fsS http://127.0.0.1:8744/api/v2/health
curl -fsS http://127.0.0.1:8744/api/v2/version
docker logs vxcloud-vxnode --tail 100
sudo nginx -t
sudo systemctl status nginx --no-pager
```

Repair the smallest failing layer: run the missing-package fix script when
needed, rerun the idempotent setup stage, recreate the container only after
backing up mounted data and `.env`, then recheck health and workspace sync.
The updater follows pull -> recreate -> health gate -> rollback; pin the
channel digest while investigating an image regression. SSL failures usually
mean DNS, 80/443, Nginx or Cloudflare state; inspect those before deleting
certificates. Never run a broad prune on a customer node without explicit
backup and approval.

For full deployment details, see this README and the restricted QuickDoc
runbooks for Vault, Cloudflare and mailcow/OVH relay. Keep secrets out of
issues, logs, commits and agent summaries.

## Verification checklist

1. Identify tenant, workspace, selected node and requested side effect.
2. Run health/version checks on the correct service.
3. For scheduled jobs, verify Celery/Redis and, when relevant, Temporal plus
   Kafka/audit events; do not trust a UI spinner alone.
4. For email, show the draft, recipient, provider and approval state; send only
   when the configured approval policy allows it, then verify delivery.
5. For deployment, build/test, deploy, HTTPS health-check and rollback criteria.
6. Redact tokens, credentials, private keys and unnecessary personal data.

Use the full guide at `../README.md` for deployment and repair commands. The
safe order is: inspect Docker/Nginx/health/version, confirm workspace ownership,
repair the smallest layer, then verify the public HTTPS route. Do not prune,
delete, rotate, or re-provision a node without explicit approval and a backup.
