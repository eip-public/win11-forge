# shellcheck shell=bash
# DesktopCommander MCP helpers shared by role-bootstrap scripts.
# Caller must set DC_URL (e.g. "http://192.168.122.100:8200/mcp")
# before calling dc_init / dc_set.

# Open a DC MCP session against $DC_URL and export SESSION for dc_set.
dc_init() {
    SESSION=$(curl -si -X POST "$DC_URL" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -d '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"setup","version":"1"}}}' \
        2>/dev/null | grep mcp-session-id | awk '{print $2}' | tr -d '\r')
}

# Set a DC config value. dc_init must have been called first.
dc_set() {
    curl -s -X POST "$DC_URL" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -H "mcp-session-id: $SESSION" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"id\":2,\"params\":{\"name\":\"set_config_value\",\"arguments\":{\"key\":\"$1\",\"value\":$2}}}" \
        >/dev/null 2>&1
}
