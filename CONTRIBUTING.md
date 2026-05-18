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
│   ├── lib/             shared helpers sourced by sibling scripts
│   │                    (ssh/log/virsh/dc options, MACs, defaults, set-disk-source.py,
│   │                    guest.sh transport dispatch, qga.py + vmrun.py host wrappers)
│   ├── setup-vm-phases/ gold-build PowerShell phase scripts; launched detached
│   │                    via launch.ps1 + runner.ps1 (avoids Windows OpenSSH wedge).
│   │                    Includes install_qga.ps1 (KVM guest agent) and
│   │                    install_vmware_tools.ps1 (invoked from backend/vmware.sh)
│   ├── third-party/     vendored upstreams (mcp-windbg etc.)
│   ├── repack-iso-noprompt.sh    rewrites the Win11 install ISO to skip the
│   │                             "Press any key to boot from CD" prompt
│   ├── disable-dc-onboarding.ps1 one-shot at role-bootstrap to silence DC's
│   │                             pendingWelcomeOnboarding prompt-injection
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
3. Anything that listens follows the existing port convention: MCP HTTP
   endpoints occupy `:8100/:8200/:8201/:8300` on the lab subnet (target
   `.100`, debugger `.101`); KDNET runs over UDP `:50000`. Pick the next
   free `:84xx` for a new MCP rather than shifting an existing port.
   Bind `0.0.0.0` inside the guest (the libvirt/VMware default network
   is private; see `SECURITY.md`).
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
- PowerShell scripts must be **ASCII-only**. No em-dashes (`—`),
  en-dashes (`–`), curly quotes, or other UTF-8 punctuation in string
  literals. PowerShell's tokenizer chokes on them after the SCP /
  encoding round-trip into the guest (silent ParserError, install
  phase fails). See commit `10ec03c` (original sweep) and the
  comments in `vm-setup/setup-vm-phases/install_qga.ps1` for the
  empirical history. Bash/Python files in the repo use em-dashes
  freely; the rule is PS1-specific.
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

## Naming conventions

These conventions are enforced by linter where possible and otherwise
documented here as the canonical source. New code must match; existing
code must not regress.

### Python (`vm-setup/*.py`, `vm-setup/lib/*.py`)

Partially enforced by `ruff check` via the `N` (pep8-naming) rule set
in `pyproject.toml`. CI fails on every rule below that is tagged
**[ruff]**; the remaining rules tagged **[convention]** are reviewed
by hand. ruff's `N` family catches class/function/argument/local
naming and mixedCase globals, but it does *not* require module-level
constants to be uppercase (e.g. `http_port = 8100` passes
`ruff check --select N` even though we want `HTTP_PORT`).

- **[ruff]** `snake_case` for functions, methods, variables,
  parameters, and attributes: `start_kd`, `pipe_appeared`,
  `_kd_log_fh` (N802/N803/N806).
- **[ruff]** `PascalCase` for classes and exceptions: `QGA`,
  `QGAError`, `ExecResult` (N801).
- **[ruff]** No mixedCase globals or arguments (N815/N816).
- **[convention]** `UPPER_SNAKE_CASE` for module-level constants:
  `HTTP_PORT`, `PIPE_TIMEOUT_S`, `KD_RESTART_DELAY`. ruff's `N` rules
  reject `mixedCase` here but accept lowercase; reviewers reject
  lowercase.
- **[convention]** `snake_case` for module filenames:
  `target_mcp_http.py`, `kd_wrapper.py`.
- **[convention]** Leading underscore `_name` for module-private
  helpers and module globals: `_run`, `_pipe_exists`, `_kd_log_fh`,
  `_shutdown`. ruff enforces this only for `__all__`-listed names;
  the broader rule is reviewer-enforced.
- **[convention]** Constants that encode a unit go in the name
  suffix: `*_S` for seconds, `*_MS` for milliseconds, `*_BYTES` /
  `*_KB` for sizes, `*_PORT` for TCP/UDP ports (`CONNECT_TIMEOUT_S`,
  `HTTP_PORT`).

### Bash (`*.sh`)

shellcheck does not enforce these directly, but the existing tree is
internally consistent and new code should match. Mismatches show up
in code review.

- `UPPER_SNAKE_CASE` for environment-overridable settings and exported
  values that drive behavior across files: `WINFORGE_BACKEND`,
  `VM_NAME`, `VM_IP`, `DISK_SIZE`, `SSH_TIMEOUT_SECONDS`. Any setting
  the user is expected to override via the shell environment goes in
  this bucket.
- `UPPER_SNAKE_CASE` for module-level (top-of-file) constants and
  derived paths: `SCRIPT_DIR`, `VM_SETUP`, `IMAGES_DIR`, `LOG_FILE`.
- `snake_case` for shell functions: `preflight`, `wait_for_ssh`,
  `_ssh_probe`, `ensure_dhcp_reservations`. A leading underscore
  marks a file-local helper (`_ssh_probe`, `_lab_wait_ssh`).
- `snake_case` for `local` variables inside functions: `local
  probe_timeout_s`, `local consecutive_ok=0`. Loop counters that
  shellcheck flagged as unused are renamed to a single underscore
  (`for _ in ...`).
- `kebab-case` for script filenames and CLI subcommands:
  `role-bootstrap-target.sh`, `seal-vm-gold.sh`, `setup.sh lab
  spawn`, `setup.sh lab load-mcp`.
- Library fragments (sourced, no shebang) live under `vm-setup/lib/`
  and carry a `# shellcheck shell=bash` directive on line 1.

### PowerShell (`*.ps1`)

PSScriptAnalyzer is not currently wired into CI, but the existing
scripts follow these conventions:

- `Verb-Noun` for cmdlet-style functions, using Microsoft-approved
  verbs (`Get-`, `Set-`, `Install-`, `Disable-`, etc.).
- `PascalCase` for variables and parameters: `$ScriptDir`, `$LogPath`,
  `$IsAuditMode`. Single-letter loop variables (`$i`) are fine inside
  tight loops.
- ASCII-only string literals (em-dashes etc. break the encoding round
  trip into the guest — see the *Style* section above).

### Lab files (`lab/CVE-YYYY-NNNNN/`)

The eight-stage pipeline reads its predecessor's output by filename;
ad-hoc names break the next stage. The canonical filenames are:
`intel_brief.md`, `diff_analysis.md`, `lab_setup_report.md`,
`poc-dev.md`, `poc_verification_report.md`, `bypass_analysis.md`,
`qa-check.md`, `disclosure.md`. See `CLAUDE.md` for the full contract.

## Tests

The repo ships [bats](https://github.com/bats-core/bats-core) suites
under `tests/`. Run only the ones that match what you touched:

```bash
bats tests/bootstrap-readiness.bats     # gold-image readiness probes
bats tests/kvm-backend.bats             # KVM/libvirt lab lifecycle
bats tests/vmware-backend.bats          # VMware lab lifecycle
bats tests/lab-lifecycle.bats           # backend-agnostic checks
```

## Linting and formatting

The repo lints and format-checks bash and Python on every push/PR via
`.github/workflows/lint.yml`. Run the same checks locally before
opening a PR:

```bash
# Bash lint — install-deps.sh, setup.sh, vm-setup/**/*.sh
# `-x` makes shellcheck follow `source` / `.` directives so the
# lib/ helpers are checked in the context that uses them.
# Portable across bash 3.2 (macOS default) and zsh — no `mapfile`.
find . -name '*.sh' \
    -not -path './vm-setup/third-party/*' \
    -not -path './lab/*' \
    -print0 | xargs -0 shellcheck -x -S warning

# Bash format — same scope. Canonical flags:
#   -i 4   4-space indent (matches the dominant existing style)
#   -ci    indent switch-case arms one level
# CI pins shfmt v3.13.1; install locally with `brew install shfmt`
# (macOS) or download the matching pinned binary from
# https://github.com/mvdan/sh/releases.
find . -name '*.sh' \
    -not -path './vm-setup/third-party/*' \
    -not -path './lab/*' \
    -print0 | xargs -0 shfmt -i 4 -ci -w   # in-place; use -d for diff

# Bash complexity — lizard caps function CCN at 12. Catches new
# functions that grow unbranched into "complex" territory.
# Install: pip install 'lizard==1.17.*' (CI uses the same pin).
lizard --languages bash -C 12 -L 1000 \
    install-deps.sh setup.sh \
    vm-setup/*.sh vm-setup/backend/*.sh vm-setup/lib/*.sh

# Python lint — vm-setup/*.py, vm-setup/lib/*.py
# Rule set, per-file ignores, and target-version live in pyproject.toml.
# C901 (mccabe) caps function CCN at 12 (see [tool.ruff.lint.mccabe]).
ruff check

# Python format — same scope and pyproject.toml block
# ([tool.ruff.format]). Black-compatible output from the same ruff
# binary; --check verifies, no flag rewrites in place.
ruff format            # write changes
ruff format --check    # CI-style verify

# Static type checking. Scope, python_version, and the strict-ish
# flag set live under [tool.mypy] in pyproject.toml. In a venv:
#   python3 -m venv .venv && .venv/bin/pip install 'mypy==1.20.*'
#   .venv/bin/mypy
mypy

# Dead-code detection. Scope, min_confidence, ignore_decorators, and
# ignore_names live under [tool.vulture] in pyproject.toml. Complements
# ruff's pyflakes (F) rules — finds unused methods/functions/classes
# that pyflakes treats as potential external API. In a venv:
#   python3 -m venv .venv && .venv/bin/pip install 'vulture==2.14'
#   .venv/bin/vulture
vulture
```

All seven checks must pass cleanly on the project's in-scope files.
The `vm-setup/third-party/` tree (vendored upstream) and `lab/`
(per-CVE scratch code) are excluded by configuration.

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
