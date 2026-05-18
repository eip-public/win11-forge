# Transport-agnostic guest command helpers shared by the role-bootstrap
# scripts. Picks qga when the libvirt domain has a working guest agent;
# otherwise falls back to ssh (legacy gold or VMware backend).
#
# Required env at source time:
#   SCRIPT_DIR — directory containing lib/qga.py (set by every caller)
#
# Optional env (set by setup.sh's _lab_spawn before calling
# role-bootstrap-*.sh; if absent, the helper falls back to ssh):
#   WINFORGE_QGA_DOMAIN  — libvirt domain name to address via qga
#
# Each caller must already define ssh_cmd(cmd) — the legacy primitive —
# before sourcing this file. The fallback path calls into it.

# Internal: cached transport selection. Set by guest_select_transport().
_GUEST_TRANSPORT=""

guest_select_transport() {
    if [[ -z "$_GUEST_TRANSPORT" ]]; then
        if [[ -n "${WINFORGE_QGA_DOMAIN:-}" ]] \
           && python3 "$SCRIPT_DIR/lib/qga.py" ping "$WINFORGE_QGA_DOMAIN" 2>/dev/null; then
            _GUEST_TRANSPORT=qga
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
    printf '[*] Guest transport: %s%s\n' "$t" \
        "$([[ "$t" == "qga" ]] && echo " (qga, no SSH worker wedge risk)" || echo " (ssh fallback)")"
}
