# Contributing to win11-forge

Thanks for the interest. This repo is a standalone Windows-CVE lab
harness: gold-image build, kernel-debug VM pair spawn, MCP wiring, and
a small skill set that drives the eight-stage `intel → diff → lab →
poc → verify → qa → report → bypass` pipeline.

## Layout

```
win11-forge/
├── install-deps.sh      host bootstrap: KVM/libvirt, ghidriff, BinExport, ...
├── setup.sh             top-level driver: install (gold build), lab spawn/start/...
├── unattend-iso/        Windows unattended installer payload (cmd, PowerShell)
├── vm-setup/            in-VM setup + lab-host helpers (bash, Python, PowerShell)
│   ├── backend/         KVM/libvirt vs VMware backend dispatch
│   ├── third-party/     vendored upstreams (mcp-windbg etc.)
│   └── *.py / *.ps1     kd_wrapper, target/debugger MCP HTTP shims, ...
├── skills/              eight-stage pipeline skill set (SKILL.md per stage)
├── lab/                 per-CVE working directories (intel, diffs, PoCs)
└── tests/               bats tests covering bootstrap and lab lifecycle
```

## Adding a lab-setup or vm-setup change

1. Decide which file owns the behavior: top-level driver (`setup.sh`),
   backend dispatch (`vm-setup/backend/...`), or a per-role bootstrap
   (`vm-setup/role-bootstrap-*`).
2. Keep KVM/libvirt and VMware paths in sync. The `lab` subcommands branch
   on `WINFORGE_BACKEND`; if you add an option to one backend, add the
   equivalent (or an explicit "not supported here") to the other.
3. Anything that listens should bind a 50000+ port on `127.0.0.1` or the
   lab subnet — match the existing MCP-endpoint convention.
4. If the change touches a guest-side payload, regenerate the gold image
   with `./setup.sh install` and confirm the lab still spawns clean.
5. Run the relevant bats suite (see *Tests* below).

## Adding a skill

1. Pick the pipeline stage. The skill set is intentionally fixed at the
   eight stages already in `skills/`; new "stages" should be the rare
   exception. Helper skills inside a stage are fine.
2. Use the same SKILL.md frontmatter pattern as the sibling skills —
   `name`, `description` as a one-sentence trigger, then the section
   bodies.
3. Define explicit `Inputs` and `Outputs` so the pipeline contract stays
   machine-readable. The downstream stage should be able to start with
   nothing but your skill's declared outputs.
4. Skill prose is for the agent. Be terse and imperative; reserve
   commentary for non-obvious constraints.

## Style

- `set -Eeuo pipefail` at the top of every bash script.
- PowerShell scripts: `Set-StrictMode -Version Latest` and
  `$ErrorActionPreference = 'Stop'` where the script does anything
  consequential.
- Python: target the version the gold image ships (currently 3.x system
  Python). No package-manager assumptions inside the guest scripts.
- Comment the *why*, not the *what*. The `vm-setup/` and
  `unattend-iso/` files in particular are full of small workarounds for
  specific Windows behaviors — those are worth a one-line explanation;
  the surrounding boilerplate is not.
- Do not vendor new binaries into the repo without flagging it in the
  PR. If a third-party artifact is needed, prefer fetch-at-install with
  a sha256 check.
- Do not leak machine-specific paths (`/Users/<name>/...`,
  `/home/<name>/...`). Use `$HOME` and the canonical lab paths.

## Tests

The repo ships [bats](https://github.com/bats-core/bats-core) suites
under `tests/`. Run only the ones that match what you touched:

```bash
bats tests/bootstrap-readiness.bats     # gold-image readiness probes
bats tests/kvm-backend.bats             # KVM/libvirt lab lifecycle
bats tests/vmware-backend.bats          # VMware lab lifecycle
bats tests/lab-lifecycle.bats           # backend-agnostic checks
```

If you change anything user-facing in `install-deps.sh` or `setup.sh`,
also run:

```bash
shellcheck install-deps.sh setup.sh
```

## Lab work in `lab/`

`lab/<CVE-YYYY-NNNNN>/` is the working directory for one CVE. The
canonical files (intel brief, diff analysis, PoC, verification report,
bypass analysis, disclosure) are produced by the pipeline skills. PRs
that add or modify a lab should keep the standard filename set so the
skills can find them; ad hoc filenames break the next stage's inputs.

Large or regenerable lab artifacts (`.gzf` Ghidra archives, `.log`
build output, Windows binaries) are covered by `.gitignore`. If a new
generated-artifact type appears, add it to `.gitignore` rather than
committing it.
