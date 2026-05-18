# Transport-agnostic guest command helpers shared by the role-bootstrap
# scripts. Picks qga (KVM) or vmrun (VMware) when their respective
# guest-agent is reachable; otherwise falls back to ssh (legacy gold or
# pre-tools-install guest).
#
# Required env at source time:
#   SCRIPT_DIR — directory containing lib/qga.py + lib/vmrun.py
#
# Optional env (set by setup.sh's _lab_spawn before calling
# role-bootstrap-*.sh; if absent, the helper falls back to ssh):
#   WINFORGE_QGA_DOMAIN   — libvirt domain name to address via qga (KVM)
#   WINFORGE_VMRUN_VMX    — .vmx path to address via vmrun (VMware)
#
# Each caller must already define ssh_cmd(cmd) — the legacy primitive —
# before sourcing this file. The fallback path calls into it.
#
# Preference order: qga > vmrun > ssh. qga is preferred over vmrun on
# the rare case both are exposed (would only happen via misconfig),
# because qga is faster and runs as LocalSystem.

# Internal: cached transport selection. Set by guest_select_transport().
_GUEST_TRANSPORT=""

guest_select_transport() {
    if [[ -z "$_GUEST_TRANSPORT" ]]; then
        if [[ -n "${WINFORGE_QGA_DOMAIN:-}" ]] \
           && python3 "$SCRIPT_DIR/lib/qga.py" ping "$WINFORGE_QGA_DOMAIN" 2>/dev/null; then
            _GUEST_TRANSPORT=qga
        elif [[ -n "${WINFORGE_VMRUN_VMX:-}" ]] \
           && python3 "$SCRIPT_DIR/lib/vmrun.py" ping "$WINFORGE_VMRUN_VMX" 2>/dev/null; then
            _GUEST_TRANSPORT=vmrun
        else
            _GUEST_TRANSPORT=ssh
        fi
    fi
    echo "$_GUEST_TRANSPORT"
}

# Run a PowerShell script in the guest. The script is the single arg.
# Returns the script's exit code; stdout+stderr forwarded to ours.
#
# Both paths now ship the script body as opaque bytes, never interpolated
# into a command line. This is the only correct way to handle arbitrary
# embedded quotes / backslashes / $ across a shell-quoting chain.
#
# qga path: pipe via stdin to `powershell -Command -` inside the guest.
# ssh path: base64-UTF16LE + `powershell -EncodedCommand`. Microsoft-
#   blessed way to ship a PS script as one opaque token. The previous
#   ssh_cmd "... -Command \"$script\"" mangled embedded quotes — the
#   schtasks /TR "C:\..." arg lost its quotes, broke role-bootstrap
#   under any backend on the SSH path.
guest_powershell() {
    local script="$1"
    case "$(guest_select_transport)" in
        qga)
            python3 "$SCRIPT_DIR/lib/qga.py" powershell \
                "$WINFORGE_QGA_DOMAIN" --timeout "${GUEST_CMD_TIMEOUT_S:-60}" <<<"$script"
            ;;
        vmrun)
            python3 "$SCRIPT_DIR/lib/vmrun.py" powershell \
                "$WINFORGE_VMRUN_VMX" --timeout "${GUEST_CMD_TIMEOUT_S:-60}" <<<"$script"
            ;;
        ssh)
            local encoded
            encoded=$(printf '%s' "$script" | iconv -t utf-16le | base64 -w0)
            ssh_cmd "powershell -NoProfile -EncodedCommand $encoded"
            ;;
    esac
}

# Run a cmd.exe command line. Each argument is one argv element to
# cmd.exe — pass them separately, do NOT pre-quote. Use guest_powershell
# for anything beyond plain `cmd /c <bare-command>`.
#
# guest_cmd /c "bcdedit /debug on"        # one cmd.exe arg
# guest_cmd /c bcdedit /debug on          # four cmd.exe args
guest_cmd() {
    case "$(guest_select_transport)" in
        qga)
            python3 "$SCRIPT_DIR/lib/qga.py" exec \
                "$WINFORGE_QGA_DOMAIN" --timeout "${GUEST_CMD_TIMEOUT_S:-60}" -- \
                cmd.exe "$@"
            ;;
        vmrun)
            python3 "$SCRIPT_DIR/lib/vmrun.py" exec \
                "$WINFORGE_VMRUN_VMX" --timeout "${GUEST_CMD_TIMEOUT_S:-60}" -- \
                'C:\Windows\System32\cmd.exe' "$@"
            ;;
        ssh)
            ssh_cmd "cmd $*"
            ;;
    esac
}

# Report which transport is in effect. For prelude logging in the
# caller — agents/operators benefit from seeing whether the run is on
# the fast/no-wedge path or the legacy path.
guest_report_transport() {
    local t; t=$(guest_select_transport)
    local note
    case "$t" in
        qga)   note=" (qga, no SSH worker wedge risk)" ;;
        vmrun) note=" (vmrun via VMware Tools, no SSH worker wedge risk)" ;;
        ssh)   note=" (ssh fallback)" ;;
        *)     note="" ;;
    esac
    printf '[*] Guest transport: %s%s\n' "$t" "$note"
}
