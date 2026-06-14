# vxnode setup.sh — Error & Blocker Report

**Scope:** standing up two tenant nodes from a Windows/WSL workstation via the
config-driven `setup.sh` + `tenant.yaml`, then a full wipe-and-reinstall (node +
browser IDE) of both. This document records every error and blocker hit, the root
cause, where it lives, the fix applied, and how it was verified — so the DevOps
team can recognise and avoid them.

**Date:** 2026-06-15
**Operator env:** Windows 11 + WSL **Ubuntu-24.04**; targets = 2× AWS Ubuntu 24.04
(`44.204.30.45` / `778ipdnsloadbalancraddress001391.vxcloud.click` and
`54.197.152.129` / `44hynewinstance96594e8c888811112.vxcloud.click`).
**Health endpoint used to verify a node:** `GET /api/v2/health` → `200 {"status":"ok"}`.

---

## Summary table

| # | Severity | Area | Symptom | Status |
|---|---|---|---|---|
| 1 | Blocker | WSL / SSH | `.pem` on `/mnt/c` rejected — `UNPROTECTED PRIVATE KEY FILE` | **Fixed** (`secure_key`) |
| 2 | Blocker | `setup.sh` driver | Only the **first** of 2 instances installed | **Fixed** (FD-3 read) |
| 3 | Blocker | `setup.sh` | `_secured_key: unbound variable` under `set -u` | **Fixed** (trap scope) |
| 4 | Blocker | SSH lifecycle | Run **hangs at 100%** after a node is fully installed | **Fixed** (stage runner + `setsid`) |
| 5 | Blocker | `tenant_setup.sh` | STEP 6 aborts: `remote tenant_setup failed` on a clean VM | **Fixed** (cron/timer) |
| 6 | Blocker | Registry | Private image won't pull without a token | **Fixed** (`docker_pat`) |
| 7 | Security | Bundle | Operator SSH keys + creds streamed to tenant VMs | **Fixed** (tar excludes) |
| 8 | Risk | Config | `tenant.yaml` vs `tenant.json` drift (`docker_pat`) | **Flagged** |
| 9 | Tooling | WSL invocation | Inline `$var` / `/mnt/c` paths mangled from Git Bash | **Worked around** |
| 10 | Tooling | Diagnostics | `ssh -n … 'sudo bash -s' <<EOF` produced no output | **Worked around** |

---

## 1. Blocker — SSH key on `/mnt/c` rejected (WSL drive mount)

**Symptom:** `setup.sh` aborts with `SSH connection failed`, or manual `ssh -i`
prints `WARNING: UNPROTECTED PRIVATE KEY FILE!` / `Permissions 0444 … are too
open` and then `Permission denied (publickey)`.

**Root cause:** Windows drive mounts under WSL (`/mnt/c`) don't carry Unix
permission metadata — files show as `0444`/`0777` and `chmod 600` is a silent
no-op. OpenSSH refuses a private key readable by group/other and falls back to
no-key auth, which then fails.

**Where:** `bin/files/cloudagentkey.pem` referenced from `tenant.yaml` while
running `setup.sh` out of `/mnt/c/.../vxnode/bin`.

**Fix:** added `secure_key()` to `setup.sh`. It tries `chmod 600`; if the perms
don't actually tighten (drvfs), it copies the key to a `0600` file under `TMPDIR`
on the real (ext4) filesystem and uses that for the session, cleaned up on exit.
You'll see the informational line: `key perms not enforceable on its filesystem
(WSL /mnt/c?) — using a private 0600 copy`.

**Verified:** SSH to both VMs succeeds; install proceeds. No operator action needed.

---

## 2. Blocker — only the first of two instances installed

**Symptom:** `setup.sh` (with 2 instances in `tenant.yaml`) finished with
`summary: 1 instance(s), 0 failed` — the second VM was never touched.

**Root cause:** the driver loop read the instance list with
`while IFS=… read … <<< "$rows"; do install_one …; done`. Inside `install_one`,
`ssh` reads **stdin**, which on a here-string loop is the row list itself — so the
first `ssh` swallowed the remaining rows. Classic "ssh eats the read loop's stdin".

**Where:** `setup.sh` → `run_rows()`.

**Fix:** read the rows on a dedicated file descriptor (`<&3` / `3<<< "$rows"`) so
`ssh`'s stdin can't consume them, plus `-n` (stdin from `/dev/null`) on every
non-piped `ssh` call as defence in depth.

**Verified:** both instance headers now appear; `summary: 2 instance(s), 0 failed`.

---

## 3. Blocker — `_secured_key: unbound variable`

**Symptom:** after an instance finished, the per-instance subshell printed
`setup.sh: line 1: _secured_key: unbound variable` and the run mis-counted.

**Root cause:** an `EXIT` trap (cleaning up the temp key from #1) referenced a
`local` variable. The trap fires **after** `install_one` returns, when the local
is already out of scope; under `set -u` that's an unbound-variable error.

**Where:** `setup.sh` → `install_one()` EXIT trap.

**Fix:** made the variable non-`local` (the per-instance subshell still isolates
it) and guarded the trap with `${_secured_key:-}`.

**Verified:** clean exit, no stray error.

---

## 4. Blocker — run "hangs at 100%" after the node is already healthy

**Symptom:** the node deployed fully (container `healthy`, `/api/v2/health` →
200, SSL issued, tools installed), but `setup.sh` never returned — `ssh` sat open
for 10–20+ min. Output froze right after the certbot dry-run line.

**Root cause (two layers):**
1. A process backgrounded during the remote stage (e.g. the fleet auto-update
   unit firing 2 min after the timer was enabled) inherited the SSH channel's
   std streams, so `ssh` wouldn't close even though `tenant_setup.sh` had exited.
2. Deeper: even after isolating output to a file, the per-session `sshd` stayed
   open because a process lingered in the SSH **login session's systemd scope**
   (`session-NN.scope`), pinning `/run/systemd/sessions/NN.ref`. `logind` keeps
   the session — and thus `sshd` — alive until that process exits.

**Diagnosis trail:** `pstree`/`ps` showed `tenant_setup.sh` gone but `sshd:
ubuntu@notty` still alive; `/proc/<sshd>/fd` had no pipes (stdio → `/dev/null`)
but **fd 9 → `/run/systemd/sessions/NN.ref`**; `loginctl`/`systemctl status
session-NN.scope` confirmed the session was being held.

**Where:** the remote-stage invocations in `setup.sh`.

**Fix:** introduced `_remote_stage_runner.sh`, which runs each stage with output
redirected to a VM-local file and streamed back live via `tail --pid` (so
backgrounded processes inherit the file, never the channel), **and** launches the
stage under `setsid -w` so the staged script and all its children land in a *new*
session — they can no longer keep the SSH login session (and `sshd`) alive.
`setup.sh` calls stages through this runner.

**Verified:** both nodes complete and `ssh` returns cleanly; the IDE stage on the
second node (which previously hung) finished with `IDE ready` and exit 0.

---

## 5. Blocker — `tenant_setup.sh` STEP 6 aborts on a clean VM

**Symptom:** on a freshly-wiped VM the run failed with `remote tenant_setup
failed`. Everything up to and including SSL succeeded; it died at
`[INFO] Setting up SSL auto-renewal...`. **Both** VMs failed identically →
`summary: 2 instance(s), 2 failed`.

**Root cause:** STEP 6's cron fallback —
`(crontab -l 2>/dev/null | grep -v certbot; echo "$CRON_CMD") | crontab -` —
is not safe under `set -euo pipefail`: on a VM with **no root crontab**,
`crontab -l` exits non-zero and `grep -v` exits 1 on no match, so the pipeline
fails and aborts the whole script. It was only reached because the wipe (item
below) had **disabled `certbot.timer`**, pushing execution into this fragile
branch instead of the normal "timer is active" path.

**Where:** `tenant_setup.sh` → STEP 6 (CERTBOT AUTO-RENEWAL).

**Fix:** prefer certbot's own systemd timer (`systemctl enable --now
certbot.timer` when the unit exists); only fall back to cron otherwise, and make
that fallback `set -e`/`pipefail`-safe (`{ crontab -l || true; } | { grep -v … ||
true; }`) and non-fatal (`… || log_warn`). Auto-renewal can never abort the install.

**Verified:** both VMs passed STEP 6, reached `SETUP COMPLETE`, and the
certbot auto-renewal timer is active.

**Note:** this was surfaced by the wipe disabling `certbot.timer`. The fix makes
`setup.sh` robust regardless of the timer's prior state — important because any
genuinely fresh VM has no root crontab.

---

## 6. Blocker — private image won't pull

**Symptom:** on a VM with no cached image, `docker pull vxcloud/vxnode:latest`
would fail (`pull access denied` / `not found`) and the container never starts.

**Root cause:** `vxcloud/vxnode` is a **private** Docker Hub repo; the pull needs
authentication. With `docker_pat` empty, `tenant_setup.sh` skips `docker login`.

**Where:** `tenant.yaml` `defaults.docker_pat` → passed to `tenant_setup.sh`.

**Fix:** set `defaults.docker_pat` to the vxcloud pull token in the operator
config. (Keep it **out** of any publicly-shared copy — see #8.)

**Verified:** image pulls and the container comes up `healthy` on both VMs.

---

## 7. Security blocker — operator secrets streamed to tenant VMs

**Symptom (latent):** the bundle `setup.sh` `tar`s to each VM included
`bin/files/` — i.e. **every** operator SSH private key, other tenants' `.pem`
files, cloud-credential JSON, and the full `tenant.yaml`/`tenant.json` inventory
(which also holds the Docker PAT). That would copy all of it onto every customer VM.

**Root cause:** the bundle `tar` only excluded a few patterns; `./files` and the
`tenant.*` configs were not among them. No remote script needs them.

**Where:** `setup.sh` → the `tar -czf - … | ssh … tar -xzf` bundle copy.

**Fix:** added `--exclude='./files' --exclude='./tenant.yaml'
--exclude='./tenant.yml' --exclude='./tenant.json'`. Only the install scripts are
shipped now.

**Verified:** bundle no longer contains keys/creds/inventory.

---

## 8. Risk — `tenant.yaml` ⇄ `tenant.json` drift

**Symptom:** in `distribution/vxnode`, `tenant.yaml` has `docker_pat: ""` (token
removed for sharing) but `tenant.json` still carries the live token.

**Why it matters:** `tenant.json` is the **exact-mirror fallback** `setup.sh`
uses when PyYAML is unavailable. If they disagree, the JSON path can pull/ship a
secret the YAML deliberately removed.

**Action:** keep the two files in sync. Recommended: blank `docker_pat` in
`distribution/.../tenant.json` to match the YAML (the operator/`bin` copy keeps the
real token). A CI check that asserts the two files are equivalent would catch this.

---

## 9. Tooling — WSL invocation from Git Bash mangles `$var` and `/mnt/c` paths

**Symptom:** `wsl.exe bash -c '… $VAR …'` ran with `$VAR` **empty** (loops
iterated but variables were blank); and `wsl.exe bash /mnt/c/tmp/x.sh` failed with
`No such file or directory` (`C:/Program Files/Git/mnt/c/…`).

**Root cause:** Git Bash (MSYS2) rewrites/expands arguments before handing them to
`wsl.exe` — single-quoted `$var` still gets stripped, and `/mnt/...` is converted
to a Windows path.

**Workaround (use this for all WSL automation):**
- Put logic in a **script file** and run `wsl.exe -d Ubuntu-24.04 bash /mnt/c/tmp/script.sh`
  instead of passing inline `-c '…$var…'`.
- Prefix the call with **`MSYS_NO_PATHCONV=1`** so `/mnt/c/...` paths survive.

---

## 10. Tooling — `ssh -n … 'sudo bash -s' <<EOF` produced no output

**Symptom:** a remote diagnostic piped via a here-doc to `sudo bash -s` returned
nothing.

**Root cause:** `ssh -n` forces stdin from `/dev/null`, so the here-doc never
reached the remote `bash -s`. (`-n` is correct for the installer; it just can't be
combined with feeding a script on stdin.)

**Workaround:** for stdin-fed remote scripts, drop `-n`; or pass the commands as a
quoted argument (`ssh … 'cmd1; cmd2'`) instead of on stdin.

---

## Non-bugs / red herrings (so they don't waste your time)

- **`certbot renew --dry-run` looks frozen.** It performs a real ACME staging
  challenge and its output buffers — the log can sit on `Processing …conf` for a
  minute or two. That's normal, not a hang (contrast with #4, which is a true hang
  *after* completion).
- **Let's Encrypt rate limits.** Re-issuing after a wipe counts against the
  per-domain weekly limit (duplicate-cert cap). We stayed well under it; just be
  aware if you wipe/reinstall the same domain many times in a week. On a re-run
  with a still-valid cert, STEP 5 reuses it (no new issuance).
- **`install_ide` / OpenClaw.** The browser IDE is installed by `setup.sh`
  (`install_ide: true`, or `--stage ide`) as a **separate** container — it never
  touches `vxcloud-vxnode`. OpenClaw is intentionally **not** installed by
  `setup.sh` (it needs provider auth) and is left to the admin.

---

## Outcome

After the fixes, a from-empty install of both nodes via `setup.sh` succeeds
end-to-end:

- both `/api/v2/health` → **200**,
- both IDEs on `:8443` → **403** without token / **302** with the
  `connection_token`,
- `vxcloud-vxnode` + `openvscode-server` containers running, real Let's Encrypt SSL.

All fixes live in `setup.sh`, `tenant_setup.sh`, and `_remote_stage_runner.sh`
and are mirrored between `bin/` and `distribution/vxnode/` (the only intentional
difference being `docker_pat` in the shared config — see #8).
