# VxCloud node agent context

This is the node-side companion to `distribution/.claude/AGENT.md`. Read it
before changing a tenant VM. It explains the sealed `vxcloud/vxnode` runtime,
the control-plane/SalesShift relationship, the port map (including VxThinking
on `8745` and the optional legacy `8746` sidecar), tenant-safe node selection,
and the health-gated repair workflow. Never place Vault values, API keys,
provider credentials, mailbox passwords or SSH private keys in source control.

Use the full guide at `../README.md` for deployment and repair commands. The
safe order is: inspect Docker/Nginx/health/version, confirm workspace ownership,
repair the smallest layer, then verify the public HTTPS route. Do not prune,
delete, rotate, or re-provision a node without explicit approval and a backup.
