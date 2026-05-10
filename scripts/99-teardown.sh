#!/usr/bin/env bash
# Reverse the provisioning steps. Safe to run if some pieces are missing.
# Does NOT touch Salesforce data — use 99-sf-clean.sh for that.

. "$(dirname "$0")/_lib.sh"
require_token

STATE_DIR="$ROOT/.state/$ENV"

# 1. agent
AGENT_ID="$(cat "$STATE_DIR/agent_id" 2>/dev/null || true)"
if [ -z "$AGENT_ID" ]; then
  AGENT_ID="$(dp_rpc redpanda.api.dataplane.v1alpha3.AIAgentService/ListAIAgents '{}' \
    | jq -r --arg n "$AGENT_DISPLAY_NAME" '.aiAgents[]? | select(.displayName == $n) | .id' | head -1)"
fi
if [ -n "$AGENT_ID" ]; then
  log "deleting agent $AGENT_ID"
  dp_rpc redpanda.api.dataplane.v1alpha3.AIAgentService/DeleteAIAgent "$(jq -nc --arg id "$AGENT_ID" '{id:$id}')" >/dev/null
fi

# 2. service account + cluster secret
SA_ID="$(cat "$STATE_DIR/sa_id" 2>/dev/null || true)"
if [ -z "$SA_ID" ]; then
  PAGE_TOKEN=""
  while :; do
    RESP="$(cp_get "/v1/service-accounts?filter.resource_group_id=$RESOURCE_GROUP_ID&page_size=200${PAGE_TOKEN:+&page_token=$PAGE_TOKEN}")"
    MATCH="$(echo "$RESP" | jq -r --arg n "$SA_NAME" '.service_accounts[]? | select(.name == $n) | .id' | head -1)"
    if [ -n "$MATCH" ]; then SA_ID="$MATCH"; break; fi
    PAGE_TOKEN="$(echo "$RESP" | jq -r '.next_page_token // ""')"
    [ -z "$PAGE_TOKEN" ] && break
  done
fi
if [ -n "$SA_ID" ]; then
  SA_ID_UPPER="$(printf '%s' "$SA_ID" | upper)"
  SECRET_NAME="SERVICE_ACCOUNT_${SA_ID_UPPER}"
  log "deleting cluster secret $SECRET_NAME"
  dp_del "/v1/secrets/$SECRET_NAME" >/dev/null || true
  log "deleting service account $SA_ID"
  cp_del "/v1/service-accounts/$SA_ID" >/dev/null || true
fi

# 3. MCP
if rpai mcp get "$MCP_NAME" >/dev/null 2>&1; then
  log "deleting MCP $MCP_NAME"
  rpai mcp delete "$MCP_NAME" >/dev/null
fi

# 4. SF_CLIENT_SECRET
log "deleting cluster secret $SF_SECRET_NAME"
dp_del "/v1/secrets/$SF_SECRET_NAME" >/dev/null || true

rm -rf "$STATE_DIR"
ok "teardown complete"
