# win11-forge code-quality audit

Read-only review of code, structure, and documentation cleanliness across
`install-deps.sh`, `setup.sh`, `vm-setup/`, `unattend-iso/`, and `tests/`.
`skills/` and `lab/` are out of scope.

Findings ordered by category, severity within category. Every claim is
file:line citable.

A **Status tracker** at the bottom of this file records which findings have
been closed, in which commit, and which are batched for a later teardown +
gold-rebuild cycle. Update it as fixes land.

---

## Real bugs

### `vm-setup/create-vm.sh` VHD branch ignores `--user`/`--password`
- [vm-setup/create-vm.sh:218-219](vm-setup/create-vm.sh): `sshpass -p 'forge123' ssh ... "forge@$TARGET_IP"` is hardcoded.
- ISO branch on [vm-setup/create-vm.sh:295-296](vm-setup/create-vm.sh) correctly uses `"$VM_PASS"` / `"$VM_USER"`.
- Symptom: any caller customizing creds runs the ISO path correctly, then
  the VHD wait loop probes with stale defaults and either hangs to
  `MAX_WAIT` or finds the wrong account on a shared host.
- Fix: replace literals with `"$VM_PASS"` / `"$VM_USER@$TARGET_IP"`.

### `vm-setup/backend/kvm.sh` `vm_state` returns non-normalized strings
- [vm-setup/backend/kvm.sh:182-191](vm-setup/backend/kvm.sh): maps
  `running`→`running`, `shut off`→`stopped`, **everything else echoes
  verbatim** (`paused`, `pmsuspended`, `crashed`, `in shutdown`).
- [vm-setup/backend/vmware.sh:246-255](vm-setup/backend/vmware.sh): only
  ever returns `running` / `stopped` / `undefined`.
- Real callers compare against the normalized vocabulary:
  [setup.sh:425-426](setup.sh), [setup.sh:486-487](setup.sh),
  [setup.sh:614](setup.sh), [setup.sh:640](setup.sh),
  [setup.sh:653](setup.sh) all do `[[ "$(vm_state ...)" == "running" ]]`
  or `!= "running"`. On KVM, a `paused` or `in shutdown` VM passes the
  `!= "running"` check but is also not actually stopped, so
  `_lab_shutdown_role` will return early thinking it's already off.
- Fix: collapse `vm_state` in `kvm.sh` to the same three-value contract:
  `running` / `stopped` / `undefined` (plus optional `unknown` with stderr
  warning).

### `setup.sh _lab_load_mcp` reports the wrong timeout to the user
- [setup.sh:545-548](setup.sh) loops `seq 1 60` × `sleep 3` = 180s.
- [setup.sh:555](setup.sh) prints `"MCP endpoint did not come up within 60s"`.
- Same pattern in [setup.sh:543](setup.sh) where the prelude says
  "up to 180s" -- so the prelude is right, the failure message is wrong.
- Fix: change `60s` → `180s` in the warn.

### `setup.sh _lab_spawn` claims `:8100` is live immediately when it isn't
- [setup.sh:597](setup.sh): `ok "Lab VMs up. Immediate MCP endpoints are
  live; ..."` then [setup.sh:605](setup.sh) prints `:8100  (debugger —
  WinDbg kernel debug tools)` with no caveat.
- [setup.sh:688](setup.sh) (`_lab_status`) correctly labels the same
  endpoint `live after first crash or load-mcp`.
- Two functions print the same table from different code; one of them is
  wrong.
- Fix: pull the endpoint table into a single helper, or copy the
  `_lab_status` wording into `_lab_spawn`.

### `kd_wrapper.py` log files are truncated on every restart
- [vm-setup/kd_wrapper.py:106](vm-setup/kd_wrapper.py):
  `open(_kd_log_path(), "w", ...)` -- mode `"w"` truncates.
- [vm-setup/kd_wrapper.py:122-123](vm-setup/kd_wrapper.py): `open(...
  "mcp-http.out.log", "w")` and same for `.err.log`.
- The whole point of the supervisor is that kd dies repeatedly across
  BSOD cycles. Each cycle wipes the previous cycle's log.
- Fix: `"a"` (append) for all three. Optionally a session header line on
  each cycle so they're still readable.

### `kd_wrapper.py` `_prompt_monitor` re-reads the entire kd.out.log every 0.5s
- [vm-setup/kd_wrapper.py:192](vm-setup/kd_wrapper.py): `content =
  open(_kd_log_path(), "r", encoding="utf-8", errors="replace").read()`.
- No incremental seek; no `last_log_size` use (the variable is declared
  at line 176 but never read or written). After hours of debugging the
  log can grow to many MB and this loop reads it fully twice a second.
- Also a file-handle issue: not in a `with` block, so the file object
  lingers until GC and on Windows that occasionally collides with kd's
  writer.
- Fix: open once, `seek(last_log_size)` on each iteration, read the new
  chunk, append to a rolling buffer, look for `"kd>"` in the new chunk
  plus the tail of the previous one.

### `kd_wrapper.py` `_start_http` exception will kill the supervisor
- [vm-setup/kd_wrapper.py:120-128](vm-setup/kd_wrapper.py): if
  `subprocess.Popen` raises (Python missing, script missing, port in
  use), the exception bubbles up through
  [vm-setup/kd_wrapper.py:289 / :309 / :318](vm-setup/kd_wrapper.py).
  The supervisor `while not _shutdown.is_set()` loop has no try/except
  around these calls.
- The whole design promises auto-restart; this single failure mode skips
  it.
- Fix: wrap each `_start_http` call in `try/except` that logs the
  exception and falls through to the next iteration / leaves
  `_http_proc = None`.

### `kd_wrapper.py` dead variable `last_log_size`
- [vm-setup/kd_wrapper.py:176](vm-setup/kd_wrapper.py): `last_log_size = 0`
  -- never read or written after declaration.
- Combined with the previous finding it suggests an incremental-read
  optimization was started and abandoned.

### `setup.sh _lab_load_mcp` runs the SSH wait check twice
- [setup.sh:502-507](setup.sh) is a 24-iteration wait loop that breaks
  on success.
- [setup.sh:508-510](setup.sh) is a *second*, single-shot SSH check
  immediately after that calls `die` on failure.
- If the first loop succeeded, the second SSH does nothing useful and
  adds 10s of latency. If it failed, the loop never broke, so the second
  probe also fails. Redundant code.
- Fix: track loop success in a flag; `die` on failure of the loop, drop
  the second probe.

### `setup.sh cmd_lab` overrides user-set `LAB_SPAWN_GUI` env var
- [setup.sh:388](setup.sh): `if [[ "$WINFORGE_BACKEND" == "vmware" ]];
  then LAB_SPAWN_GUI=1; else LAB_SPAWN_GUI=0; fi` runs unconditionally.
- An `export LAB_SPAWN_GUI=1` from the parent shell is stomped before
  the for-arg-loop on [setup.sh:389-394](setup.sh) gets a chance to
  honor `--gui`/`--nogui`.
- Inconsistent with the pattern other settings use
  (`VM_NAME="${VM_NAME:-...}"` etc).
- Fix: `LAB_SPAWN_GUI="${LAB_SPAWN_GUI:-$default_for_backend}"`.

### `vm-setup/role-bootstrap-target.sh` mixes cmd and PowerShell in one SSH command
- [vm-setup/role-bootstrap-target.sh:161](vm-setup/role-bootstrap-target.sh):
  `ssh_cmd 'schtasks /End /TN TargetMcpWindbgBoot 2>$null ;
  Get-Process mcp-windbg -EA SilentlyContinue | Stop-Process ...'`
- `2>$null` is PowerShell syntax; the `;` separator and `Get-Process |
  Stop-Process` pipeline is PowerShell. But the SSH default shell on
  Windows OpenSSH is `cmd.exe` unless explicitly changed.
- [unattend-iso/winforge-bootstrap.ps1:50](unattend-iso/winforge-bootstrap.ps1)
  does set `DefaultShell` to `powershell.exe`, so this happens to work
  in this codebase. But it's an unstated dependency: this one line
  breaks the moment someone changes that key.
- Fix: explicit `powershell -NoProfile -Command "..."` wrapper, or
  assert the DefaultShell key from the role-bootstrap script.

### `vm-setup/create-vm.sh` chmod-walks up parent directories
- [vm-setup/create-vm.sh:172-177](vm-setup/create-vm.sh):
  ```
  DIR="$IMAGES_DIR"
  while [[ "$DIR" != "/" ]]; do
      chmod o+rx "$DIR" 2>/dev/null || true
      DIR=$(dirname "$DIR")
  done
  ```
- Walks from `vm-images/` up to `/`, applying `o+rx` to every parent,
  including `/Users/<you>/EIP/win11-forge`, `/Users/<you>/EIP`,
  `/Users/<you>/`. Silently expands world-readability across the user's
  home.
- Real cleanliness/safety bug -- the goal (let `libvirt-qemu` read the
  qcow2) is better served by adding the qemu user to a group, or using
  `setfacl`.
- Fix: stop the loop at `$HOME` or `/var/lib`; or document that this is
  required and add an opt-out env var.

### `vm-setup/backend/vmware.sh` subnet detection is one-shot at source time
- [vm-setup/backend/vmware.sh:25-31](vm-setup/backend/vmware.sh):
  `_VMWARE_SUBNET="$(_vmware_detect_vmnet8_subnet)" ||
  _VMWARE_SUBNET="172.16.87"` runs when the file is sourced.
- `TARGET_IP="${_VMWARE_SUBNET}.100"` is then frozen for the life of
  the script.
- If `vmnet8` isn't up at source time, the constants take the hardcoded
  fallback. Subsequent operations using `$TARGET_IP` then point at the
  wrong subnet, even if `vmware-networks --start` runs later in
  `backend_preflight`.
- Fix: detect lazily inside the functions that need IPs; or call
  detection from `backend_preflight` and re-export.

---

## Resource & error-handling gaps

### Pervasive `|| true` swallowing of `virsh` failures
- [setup.sh:295](setup.sh), [setup.sh:330](setup.sh),
  [setup.sh:337](setup.sh), [setup.sh:344](setup.sh),
  [setup.sh:351-355](setup.sh),
  [vm-setup/backend/kvm.sh:106-107](vm-setup/backend/kvm.sh),
  [vm-setup/backend/kvm.sh:168](vm-setup/backend/kvm.sh),
  [vm-setup/backend/kvm.sh:176-177](vm-setup/backend/kvm.sh),
  [vm-setup/seal-vm-gold.sh:241](vm-setup/seal-vm-gold.sh),
  [vm-setup/seal-vm-gold.sh:244](vm-setup/seal-vm-gold.sh),
  [vm-setup/create-vm.sh:141-146](vm-setup/create-vm.sh).
- Every destroy/undefine/snapshot-delete is `|| true`. If libvirt is in
  a bad state, the script proceeds as if cleanup succeeded and then
  collides at the next step (file lock, "domain is already defined",
  etc).
- Fix: keep `|| true` only where the precondition is genuinely "may or
  may not exist"; everywhere else, capture the exit code, log a warning
  with the actual failure text, and decide whether to die.

### Schedules tasks are created but never verified to start
- [vm-setup/role-bootstrap-target.sh:88-93](vm-setup/role-bootstrap-target.sh)
  (`TargetDesktopBoot`),
  [vm-setup/role-bootstrap-target.sh:169-177](vm-setup/role-bootstrap-target.sh)
  (`TargetMcpWindbgBoot`),
  [vm-setup/role-bootstrap-debugger.sh:101-106](vm-setup/role-bootstrap-debugger.sh)
  (`DebuggerBoot`),
  [vm-setup/role-bootstrap-debugger.sh:131-136](vm-setup/role-bootstrap-debugger.sh)
  (`DebuggerDesktopBoot`).
- `schtasks /Create /F` overwrites unconditionally; `schtasks /Run`
  returns 0 even if the action immediately fails (e.g. python.exe path
  wrong, script missing). The HTTP probe loops downstream catch *some*
  of these failures (HTTP not coming up), but `DebuggerBoot` itself has
  no probe -- if `kd_wrapper.py` crashes immediately, the
  role-bootstrap script reports success.
- Fix: after `/Run`, poll `schtasks /Query /TN ... /V /FO CSV` for
  `Last Result == 0` and `Status == Running`; fail fast if the task
  isn't actually running.

### `unattend-iso/install-winforge-bootstrap.ps1` swallows the OpenSSH installer failure
- [unattend-iso/install-winforge-bootstrap.ps1:25](unattend-iso/install-winforge-bootstrap.ps1):
  `& powershell.exe -NoProfile -ExecutionPolicy Bypass -File
  $OpenSshInstallScript` is run with no `$LASTEXITCODE` check.
- If `install-sshd.ps1` fails, control flows into
  `Register-ScheduledTask` and the gold image continues to seal as if
  SSH is set up.
- Companion script
  [unattend-iso/winforge-bootstrap.ps1](unattend-iso/winforge-bootstrap.ps1)
  has full try/catch + `ready.json` error reporting; this one has
  neither logging nor exit-code checks.
- Fix: `if ($LASTEXITCODE -ne 0) { throw ... }` after the nested call.
  Append to a log under `C:\winforge\` like the sibling script does.

### `kd_wrapper.py` opens log files without a context manager
- [vm-setup/kd_wrapper.py:122-123](vm-setup/kd_wrapper.py):
  `out = open(...)` / `err = open(...)`. Held by Popen for the child
  process lifetime, fine. But on supervisor restart the parent
  reference is reassigned and the previous file objects rely on GC for
  close. On Windows that occasionally interacts badly with the log file
  being held open by the dying child.
- Fix: keep the previous `out`/`err` handles tracked alongside
  `_http_proc` so `_stop()` can close them after `proc.wait()`.

### `vm-setup/setup-vm.sh` mcp-windbg install isn't gated on success
- [vm-setup/setup-vm.sh:395-396](vm-setup/setup-vm.sh):
  `phase_satisfied "mcp_windbg" '...' && mark_phase_done "mcp_windbg"`
  -- if `phase_satisfied` returns false, `mark_phase_done` doesn't run
  and... nothing else happens. No `else` arm to fail loudly.
- Compare with [vm-setup/setup-vm.sh:121-124](vm-setup/setup-vm.sh)
  (`run_phase`) which DOES `return 1` on verification failure.
- The mcp_windbg block bypasses `run_phase` because of the conditional
  install branching, but the failure-handling parity is lost.
- Fix: replace with `if phase_satisfied ...; then mark_phase_done; else
  echo "[-] ..."; exit 1; fi`.

### `vm-setup/seal-vm-gold.sh wait_for_ssh` will silently no-op with bad config
- [vm-setup/seal-vm-gold.sh:150](vm-setup/seal-vm-gold.sh):
  `loops=$((SSH_TIMEOUT_SECONDS / 5))`.
- If a user sets `SSH_TIMEOUT_SECONDS=abc`, bash arithmetic produces 0
  and the `for ((i=1; i<=0; i++))` loop runs zero times -- function
  returns failure immediately with no diagnostic.
- Fix: validate `SSH_TIMEOUT_SECONDS` with
  `[[ "$SSH_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]]` at script start, the same
  way [setup.sh:665](setup.sh) validates `LAB_STOP_GRACE`.

### `install-deps.sh install_binexport_plugin` skips silently
- [install-deps.sh:116-117](install-deps.sh): two `return 0`
  early-exits with no log message ("ghidra missing" or "BinExport
  already present"). Also the BinExport download failure on
  [install-deps.sh:138-139](install-deps.sh) is `warn + return 0`.
- A user who can't figure out why diff stage fails has no install-time
  signal.
- Fix: `log` the skip reason in both early-return paths; return
  non-zero on the download path so `install_mode` can decide.

---

## Architecture & duplication

### Inline `xml.etree` Python heredoc is duplicated verbatim
- [setup.sh:307-319](setup.sh) and
  [vm-setup/seal-vm-gold.sh:195-215](vm-setup/seal-vm-gold.sh):
  essentially the same "rewrite primary disk source in domain XML"
  Python.
- One place uses for-else, the other uses for + else clause; same
  behavior, different style.
- Fix: extract to `vm-setup/lib/set-disk-source.py` (or sh function
  calling a shared helper). The two callers call it with
  `<vm_name> <new_path>`.

### Three sources of truth for VM MAC addresses
- [setup.sh:71](setup.sh): `GOLD_MAC="52:54:00:11:11:11"`.
- [vm-setup/backend/kvm.sh:41-42](vm-setup/backend/kvm.sh):
  `TARGET_MAC="52:54:00:11:11:11"`, `DEBUGGER_MAC="52:54:00:22:22:22"`.
- [vm-setup/create-vm.sh:41](vm-setup/create-vm.sh):
  `VM_MAC="${VM_MAC:-52:54:00:11:11:11}"`.
- [install-deps.sh:307](install-deps.sh):
  `target_mac="00:50:56:11:11:11"; debugger_mac="00:50:56:22:22:22"`
  (VMware).
- [vm-setup/backend/vmware.sh:40-41](vm-setup/backend/vmware.sh): same
  VMware MACs.
- Four places in code, two backends. Drift is inevitable.
- Fix: a single shared file (e.g. `vm-setup/macs.env`) sourced by both
  backends and `install-deps.sh`; or move VMware-side reservation into
  `vm-setup/backend/vmware.sh` and call it from `install-deps.sh`.

### `setup-vm.sh` long inline PowerShell strings with `'\''` escape stacking
- [vm-setup/setup-vm.sh:233](vm-setup/setup-vm.sh) (the `Test-Path
  '\''C:\ProgramData\chocolatey\bin\choco.exe'\''` pattern repeats 6+
  times in `phase_satisfied` calls), and
  [vm-setup/setup-vm.sh:265, 290, 309, 326, 373](vm-setup/setup-vm.sh).
- Each of these embeds 100+ chars of PowerShell as a single bash
  single-quoted string; literal single quotes inside it are escaped as
  `'\''`. The 250-char `phase_satisfied` argument on line 250 is a
  particular eyesore -- nested escaping for
  `\"HKLM:\\SOFTWARE\\...\"` four levels deep.
- Fix: move each verifier and each install script to its own `.ps1`
  under `vm-setup/phase-scripts/`; `phase_satisfied "marker"
  "$(< vm-setup/phase-scripts/marker_verify.ps1)"`. Same for the
  install body.

### `setup-vm.sh` runs `iex ((New-Object
System.Net.WebClient).DownloadString(...))` for chocolatey
- [vm-setup/setup-vm.sh:241](vm-setup/setup-vm.sh): the standard
  Chocolatey install line. Pinning a hash isn't possible here because
  Chocolatey uses redirects, but you could at minimum capture the
  script to a file first and assert a SHA. Project explicitly disables
  Defender so this runs hot.
- Note only -- this is the documented chocolatey flow.

### Duplicate ssh-helper functions across role-bootstrap scripts
- [vm-setup/role-bootstrap-target.sh:28-38](vm-setup/role-bootstrap-target.sh)
  and
  [vm-setup/role-bootstrap-debugger.sh:26-45](vm-setup/role-bootstrap-debugger.sh):
  near-identical `ssh_cmd`, `scp_to`, `wait_for_ssh`. Debugger adds
  `retry_ssh_cmd` / `retry_scp_to`; target doesn't.
- [vm-setup/setup-vm.sh:54-74](vm-setup/setup-vm.sh) has its own
  `ssh_cmd` / `scp_to` with key-vs-password fallback.
- [vm-setup/seal-vm-gold.sh:98-125](vm-setup/seal-vm-gold.sh) has yet
  another pair (`ssh_base` / `scp_base`) with BatchMode +
  ServerAliveInterval baked in.
- Four implementations of the same idea, none reuse each other. The
  retry-with-backoff logic exists only in role-bootstrap-debugger.sh
  -- the others happily fail on a transient.
- Fix: one `vm-setup/lib/ssh-helpers.sh` sourced by all four. Single
  retry policy.

### Three different logging styles across bash scripts
- [install-deps.sh:52-55](install-deps.sh): colored `[+]/[!]/[-]/[*]`
  prefix, no timestamp.
- [setup.sh:91-94](setup.sh): same colors, but `log()` adds a
  timestamp; others don't.
- [vm-setup/seal-vm-gold.sh:94-96](vm-setup/seal-vm-gold.sh):
  bracketed timestamp only, no colors, no `ok/warn/die` distinction.
- [vm-setup/setup-vm.sh](vm-setup/setup-vm.sh): just `echo "[*] ..."`
  everywhere, no helpers.
- [vm-setup/role-bootstrap-target.sh](vm-setup/role-bootstrap-target.sh):
  same plain `echo`.
- [vm-setup/role-bootstrap-debugger.sh:76-77](vm-setup/role-bootstrap-debugger.sh):
  defines `ok` / `warn` only, used inconsistently with plain `echo`
  further down.
- Fix: consolidate into one `vm-setup/lib/log.sh` providing
  `log/ok/warn/die` and source from every executable script.

### Two sets of constants for the gold image name and IP defaults
- [setup.sh:61-65, 71-73](setup.sh) defines `VM_NAME`, `VM_IP`,
  `GOLD_MAC`, `GOLD_IP`, `CURRENT_GOLD_IP` (all four IPs are the same
  value).
- [vm-setup/create-vm.sh:24-41](vm-setup/create-vm.sh) re-declares
  `VM_NAME`, `VM_RAM`, `VM_CPUS`, `DISK_SIZE`, `VM_IP`, `VM_USER`,
  `VM_PASS`, `VM_MAC` with the same defaults.
- The fields are then passed *both* as env (`VM_CPUS=...`) *and* as
  flags (`--cpus ...`) at [setup.sh:234-241](setup.sh). Pick one mode.
- `CURRENT_GOLD_IP` is set on [setup.sh:73](setup.sh) and never read
  anywhere else in the file. Dead variable.
- Fix: one defaults file, sourced; pass via env *or* flags, not both;
  delete `CURRENT_GOLD_IP`.

### Stale name `PHASE0_DIR` everywhere
- [vm-setup/create-vm.sh:20](vm-setup/create-vm.sh),
  [vm-setup/setup-vm.sh:17](vm-setup/setup-vm.sh),
  [vm-setup/seal-vm-gold.sh:17](vm-setup/seal-vm-gold.sh) all do
  `PHASE0_DIR="$(dirname "$SCRIPT_DIR")"` -- it's just the repo root.
  The "phase 0" framing isn't reflected anywhere else in the codebase.
- Fix: rename to `REPO_ROOT`.

### `dc_set` JSON-quoting helper duplicated between role-bootstrap scripts
- [vm-setup/role-bootstrap-target.sh:121-128](vm-setup/role-bootstrap-target.sh)
  and
  [vm-setup/role-bootstrap-debugger.sh:158-165](vm-setup/role-bootstrap-debugger.sh)
  define identical `dc_set` functions. Both end with `dc_set
  "allowedDirectories" "[\"C:\\\\\\\\\"]"` -- 8 backslashes in source
  for `C:\\` in JSON. If you ever need to change the JSON shape this
  lives in two places.
- Fix: one shared shell function or a small Python helper that takes
  key/value and posts.

---

## Style & convention drift

### `set -E` missing from every executable bash script
- Project doc requires `set -Eeuo pipefail`. Actually present in 0
  scripts.
- [install-deps.sh:11](install-deps.sh), [setup.sh:41](setup.sh),
  [vm-setup/setup-vm.sh:14](vm-setup/setup-vm.sh),
  [vm-setup/seal-vm-gold.sh:14](vm-setup/seal-vm-gold.sh) (this one
  even has `trap on_error ERR` -- exactly where `-E` matters),
  [vm-setup/create-vm.sh:17](vm-setup/create-vm.sh),
  [vm-setup/role-bootstrap-target.sh:21](vm-setup/role-bootstrap-target.sh),
  [vm-setup/role-bootstrap-debugger.sh:17](vm-setup/role-bootstrap-debugger.sh),
  [vm-setup/qcow2-to-vmware.sh:17](vm-setup/qcow2-to-vmware.sh): all
  `set -euo pipefail` only.
- Fix: single sweep adding `-E`.

### Mixed shebangs
- `#!/usr/bin/env bash`: [install-deps.sh](install-deps.sh),
  [setup.sh](setup.sh),
  [vm-setup/role-bootstrap-target.sh](vm-setup/role-bootstrap-target.sh),
  [vm-setup/role-bootstrap-debugger.sh](vm-setup/role-bootstrap-debugger.sh),
  `vm-setup/backend/*.sh`.
- `#!/bin/bash`: [vm-setup/setup-vm.sh:1](vm-setup/setup-vm.sh),
  [vm-setup/seal-vm-gold.sh:1](vm-setup/seal-vm-gold.sh),
  [vm-setup/create-vm.sh:1](vm-setup/create-vm.sh),
  [vm-setup/qcow2-to-vmware.sh:1](vm-setup/qcow2-to-vmware.sh).
- Fix: `#!/usr/bin/env bash` everywhere.

### Two `vm-setup/*.ps1` files miss strict mode
- [vm-setup/setup-desktop-commander.ps1](vm-setup/setup-desktop-commander.ps1):
  no `Set-StrictMode`, no `$ErrorActionPreference`.
- [vm-setup/kd_break.ps1](vm-setup/kd_break.ps1): same.
- Both run `Add-Type` / file writes that benefit from strict mode.
  Project's `unattend-iso/*.ps1` audit-mode exception doesn't apply
  here.

### Three different Python logging strategies across the three scripts
- [vm-setup/kd_wrapper.py:55-62](vm-setup/kd_wrapper.py): file +
  stdout handler.
- [vm-setup/target_mcp_http.py:35-42](vm-setup/target_mcp_http.py):
  file + stdout handler.
- [vm-setup/windbg_mcp_http.py:39](vm-setup/windbg_mcp_http.py):
  `logging.basicConfig(...)` only -- defaults to stderr, no file.
- Fix: pick one. Per the project's user rule (MCP servers log to
  stderr, not stdout), the two stdout handlers should be `sys.stderr`
  and the windbg one should optionally add a file handler to match.

### Python: missing type hints, multi-import line
- [vm-setup/kd_wrapper.py:29](vm-setup/kd_wrapper.py): `import
  subprocess, os, sys, time, logging, pathlib, threading, signal` -- 8
  modules on one line, against PEP 8.
- Most functions in `kd_wrapper.py` lack type hints (`_start_kd(cycle)`,
  `_start_http()`, `_wait_for_kd_connect(proc, cycle)`). The two MCP
  files have only `def main() -> int` typed.
- Project-stated style: PEP 8 + type hints for Python. Inconsistent
  application.

### `vm-setup/target_mcp_http.py` dead code
- [vm-setup/target_mcp_http.py:21](vm-setup/target_mcp_http.py):
  `HERE = Path(__file__).parent` declared, never used.

### `setup.sh` help command parsing is brittle
- [setup.sh:700](setup.sh): `sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//'
  | head -n -2` -- prints the file from line 2 until it hits
  `set -euo`. If the line ever becomes `set -Eeuo` per the rule above,
  this regex breaks silently and `setup.sh help` will print the entire
  file.
- Fix: sentinel-based extraction (`# ── HELP_END ──`) or
  `sed -n '2,/^set -.euo/p'`.

### `setup.sh _lab_status` and `_lab_spawn` print divergent endpoint tables
- Compare [setup.sh:597-608](setup.sh) and
  [setup.sh:680-689](setup.sh): same data, different formatting,
  different endpoint annotations (e.g. `:8300` is "LIVE after spawn"
  in one, plain in the other; `:8100` carries a caveat in one, not the
  other).
- Fix: one helper function, both callers use it.

### `setup.sh` lab-flag parser doesn't shift consumed flags
- [setup.sh:389-394](setup.sh): for-loop reads `--gui`/`--nogui` from
  `"$@"` but never `shift`s them out. Subsequent positional access
  (`$1` for `console <role>` on line 405) works only because `console`
  accepts a single role and ignores the leftover `--gui`. Brittle.
- Fix: real argument parser or remove via `set -- ...` filter.

### `_lab_kd_connected` opens a fresh SSH connection on every poll
- [setup.sh:414-419](setup.sh) called from
  [setup.sh:446-449](setup.sh) for up to 60 polls × 3s. Each one is a
  full SSH connect. SSH `ControlMaster` is unset, no session reuse.
- Fix: one SSH session that loops `findstr` server-side, or use
  `ControlMaster=auto -ControlPath /tmp/...`.

### Tests cover ~10% of `setup.sh` surface
- `setup.sh` exposes: `install`, `status`, `reset`, `start`, `stop`,
  `destroy`, plus 9 lab subcommands (`spawn`, `start`, `stop`,
  `reset`, `destroy`, `status`, `wait-kd`, `load-mcp`, `console`).
- [tests/lab-lifecycle.bats](tests/lab-lifecycle.bats) tests 3 of the
  15 verbs (lab `start`, `stop`, `spawn`), all KVM-only.
- [tests/kvm-backend.bats](tests/kvm-backend.bats) tests
  `vm_provision` (1 test).
- [tests/vmware-backend.bats](tests/vmware-backend.bats) tests
  `vm_start` gui/nogui (4 tests).
- [tests/bootstrap-readiness.bats](tests/bootstrap-readiness.bats)
  tests role-bootstrap MCP failure paths (2 tests).
- Zero coverage of `lab reset`, `lab destroy`, `lab status`,
  `lab wait-kd`, `lab load-mcp`, `lab console`, `cmd_destroy`,
  `cmd_reset`. Zero coverage of `vm_provision`/`vm_undefine`/`vm_state`
  on the VMware backend.
- Brittle assertion: [tests/lab-lifecycle.bats:113](tests/lab-lifecycle.bats)
  uses exact-string `=` match on a multi-line file -- any prefix tweak
  breaks it.
- Fix: at minimum add VMware-mocked variants of the lifecycle tests;
  add destroy-path coverage; switch to substring or per-line
  assertions.

---

## What I checked and was OK

- `kd_wrapper.py` upholds the documented invariants: stdin held as
  `subprocess.PIPE`
  ([vm-setup/kd_wrapper.py:113](vm-setup/kd_wrapper.py)), no `-b`/`-c`
  on `kd` ([vm-setup/kd_wrapper.py:111-117](vm-setup/kd_wrapper.py)),
  prompt-monitor injection over stdin, independent supervisor restart
  loops for kd and HTTP including the late-pipe branch
  ([vm-setup/kd_wrapper.py:307-321](vm-setup/kd_wrapper.py)).
- `kd_break.ps1` uses `NtSystemDebugControl` command 6
  ([vm-setup/kd_break.ps1:13](vm-setup/kd_break.ps1)). No
  `virsh inject-nmi` anywhere.
- `seal-vm-gold.sh` is the only script with proper `trap on_error ERR`
  cleanup
  ([vm-setup/seal-vm-gold.sh:127-139](vm-setup/seal-vm-gold.sh)). The
  flatten-to-temp-then-mv pattern at
  [vm-setup/seal-vm-gold.sh:343-347](vm-setup/seal-vm-gold.sh) is
  correct (avoids breaking the backing chain).
- `vmware.sh` gold-vmdk staleness logic + base-snapshot
  delete-before-overwrite is correct and well-commented
  ([vm-setup/backend/vmware.sh:135-163](vm-setup/backend/vmware.sh)).
- `install-deps.sh download_iso_if_missing` correctly uses `.partial` +
  atomic `mv` ([install-deps.sh:81-96](install-deps.sh)).
- `setup.sh` `sg libvirt` re-exec for fresh group membership
  ([setup.sh:48-52](setup.sh)) is a nice ergonomic touch.
- `seal-vm-gold.sh verify_guest` correctly suspends `set -e` only
  across the SSH call that captures both output and exit code
  ([vm-setup/seal-vm-gold.sh:279-282](vm-setup/seal-vm-gold.sh)).
- Bats stubs use proper `set -euo pipefail` inside the mock scripts.
  Test infrastructure itself is clean.

---

## Status tracker

Last updated: 2026-05-13.

Legend:
- **fixed** — landed in commit; lab-validated.
- **partial** — some sites fixed; remaining sites listed.
- **open / Phase A** — lab-exercisable in current spawn state. Next-up.
- **open / Phase B** — architecture refactor; lab-exercisable via `lab destroy && lab spawn` cycle. No gold rebuild needed.
- **open / Phase C** — needs a full `setup.sh install` (gold rebuild, ~40 min). Batch these and ship in one rebuild cycle.
- **open / Phase D** — host-install path (`install-deps.sh`); test on a clean host or in a sandbox.
- **won't fix** — audit explicitly marked "note only" or out of scope.

### Real bugs (13 / 13 closed)

- create-vm.sh VHD branch ignores --user/--password — **fixed** in cbefb34
- backend/kvm.sh vm_state non-normalized — **fixed** in 1b48ad4
- _lab_load_mcp reports wrong timeout — **fixed** in 47af367
- _lab_spawn claims :8100 live immediately — **fixed** in de61d52
- kd_wrapper.py log files truncated on every restart — **fixed** in ad94c15
- _prompt_monitor re-reads the entire kd.out.log — **fixed** in 5d95e48
- _start_http exception kills supervisor — **fixed** in ef2ed1e
- kd_wrapper.py dead variable last_log_size — **fixed** in 5d95e48
- _lab_load_mcp runs SSH wait twice — **fixed** in 47af367
- cmd_lab overrides parent-shell LAB_SPAWN_GUI — **fixed** in 8adb93f
- role-bootstrap-target.sh mixes cmd and PowerShell — **fixed** in a4eb9e1 (line 161) + edaff16 (line 150, same pattern, swept together)
- create-vm.sh chmod-walks up parent directories — **fixed** in db0419a
- vmware.sh subnet detection one-shot at source — **fixed** in 383d103

### Resource & error-handling gaps (3 / 7 closed, 2 partial, 2 deferred)

- Pervasive `|| true` swallowing virsh failures — **partial**:
    - KVM lab paths (backend/kvm.sh: 106-107, 168, 176-177) — **fixed** in 0129503
    - setup.sh single-VM mode (295, 330, 337, 344, 351-355) — **fixed** in f654d07 (replaced with virsh_or_warn from lib/virsh-helpers.sh)
    - seal-vm-gold.sh (241, 244) — **fixed** in f654d07
    - create-vm.sh (141-146) — **fixed** in f654d07
- Schedules tasks `/Run` never verified to start — **fixed** in 70bf563
- install-winforge-bootstrap.ps1 swallows OpenSSH installer failure — **fixed** in cbe48b0 ($LASTEXITCODE check + Tee to install-sshd.log)
- kd_wrapper.py opens log files without a context manager — **partial**:
    - `_prompt_monitor` log_fh — **fixed** in 6f24798 (try/finally)
    - `_start_http` out/err handles — **fixed** in 8ece2db
- setup-vm.sh mcp-windbg install isn't gated on success — **fixed** in cbe48b0 (explicit if/else with exit 1 on verification failure)
- seal-vm-gold.sh wait_for_ssh silently no-ops with bad config — **fixed** in cbe48b0 (SSH_TIMEOUT_SECONDS regex + minimum value validation)
- install-deps.sh install_binexport_plugin skips silently — **open / Phase D**

### Architecture & duplication (0 / 8 closed)

- Inline xml.etree heredoc duplicated — **fixed** in 5f95243 (extracted to vm-setup/lib/set-disk-source.py)
- Three sources of truth for VM MAC addresses — **fixed** in 301a3ba (vm-setup/lib/macs.env sourced by defaults.sh, backend/kvm.sh, backend/vmware.sh, install-deps.sh)
- setup-vm.sh long inline PowerShell heredocs — **fixed** in 8728e55 (8 heredocs extracted to vm-setup/setup-vm-phases/; install_tools.ps1 added in 71cf918 with vcredist2015 workaround + $LASTEXITCODE checks)
- setup-vm.sh runs `iex` for chocolatey — **won't fix** (audit marked "note only"; documented chocolatey flow)
- Duplicate ssh-helper functions across 4 scripts — **fixed** in fa54863 (shallow extract — only the truly-shared SSH options block into vm-setup/lib/ssh-helpers.sh's SSH_OPTS_COMMON array; per-script auth/timeout/output behavior preserved)
- Three different logging styles across bash scripts — **fixed** in e38ecb3 (shallow extract of ok/warn/die into vm-setup/lib/log.sh; each script keeps its own log() because conventions differ intentionally)
- Two sets of constants for gold image name and IP defaults + dead `CURRENT_GOLD_IP` — **fixed** in 21e7900 (extracted to vm-setup/lib/defaults.sh, GOLD_MAC→VM_MAC, GOLD_IP→VM_IP, CURRENT_GOLD_IP deleted, env-vs-flag dup at cmd_install dropped)
- Stale name PHASE0_DIR — **fixed** in e6e7208
- dc_set JSON-quoting helper duplicated — **fixed** in 4eddc46 (extracted dc_init + dc_set to vm-setup/lib/dc-helpers.sh)

### Style & convention drift (3 / 9 closed)

- `set -E` missing from every executable bash script — **fixed** in c27fa92 (sweep of 8 scripts; -E now matters for seal-vm-gold.sh's ERR trap, no-op but uniform for the rest)
- Mixed shebangs — **fixed** in c27fa92 (4 scripts normalized to #!/usr/bin/env bash)
- Two vm-setup/*.ps1 files miss strict mode — **fixed** in cbe48b0 (setup-desktop-commander.ps1 + kd_break.ps1 now Set-StrictMode -Version Latest + ErrorActionPreference = 'Stop')
- Three different Python logging strategies across 3 scripts — **fixed** in cbe48b0 (kd_wrapper.py / target_mcp_http.py / windbg_mcp_http.py now all use file + sys.stderr handlers)
- Python: missing type hints, multi-import line — **fixed** in ba87504 (kd_wrapper.py imports split PEP 8 style, type hints on all 10 functions)
- vm-setup/target_mcp_http.py dead `HERE` — **fixed** in 498b948
- setup.sh help command parsing brittle — **fixed** in 4c5f53f
- _lab_status / _lab_spawn divergent endpoint tables — **fixed** in de61d52
- setup.sh lab-flag parser doesn't shift consumed flags — **fixed** in 9f39c4b
- _lab_kd_connected opens a fresh SSH connection on every poll — **won't fix** (measured 2026-05-13: ControlMaster=auto saves ~0.35s/poll, ~21s off a 180s wait. Dominant cost is cmd.exe+findstr inside the Windows guest, not the SSH handshake. Mux works mechanically — socket lifecycle clean, Windows OpenSSH honors the multiplexed channel — but the impact is below the threshold to justify the added cleanup discipline.)
- Tests cover ~10% of setup.sh surface — **open / separate effort** (`tests/*.bats` expansion)

### Discovered outside the audit (also fixed)

- create-vm.sh `-f vpc` hardcoded breaks VHDX inputs — **fixed** in aee7315
- role-bootstrap-target.sh:150 HAS_MCP_WINDBG raw-PS over ssh_cmd — **fixed** in edaff16 (swept with role-bootstrap-target.sh:161)
- setup-vm.sh:250 choco-reboot registry check silently broken — **fixed** in edaff16 (\\" escape doesn't work in outer-PS-as-shell context)
- New standalone helpers fetch-windev-vhd.sh + fetch-isos.sh — **added** in 0abff60
- Docs trees refreshed + VHD/VHDX path noted — **fixed** in 708ec80
