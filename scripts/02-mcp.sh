#!/usr/bin/env bash
# Idempotently create or update the Salesforce managed MCP via rpai.
#
# We don't use `rpai mcp update` — config diffs across rpai versions are
# fiddly. We compute desired config and compare with `rpai mcp get`; if
# anything changed we delete + re-create. The MCP is stateless (just a
# wrapper around the SF REST API), so re-creating is safe.

. "$(dirname "$0")/_lib.sh"
require_token

CONFIG_JSON="$(jq -nc --arg org "$SF_ORG_URL" --arg ver "$SF_API_VERSION" \
                     --arg cid "$SF_CLIENT_ID" --arg ref "$SF_SECRET_NAME" \
                     --arg tok "${SF_ORG_URL}/services/oauth2/token" \
  '{
    "@type":"SalesforceMCPConfig",
    org_url:$org,
    api_version:$ver,
    oauth:{client_id:$cid, client_secret_ref:$ref, token_url:$tok}
  }')"

EXISTS="$(rpai mcp get "$MCP_NAME" -o json 2>/dev/null | jq -r '.name // empty')"
if [ -n "$EXISTS" ]; then
  log "MCP '$MCP_NAME' exists — recreating to apply latest config"
  rpai mcp delete "$MCP_NAME" >/dev/null
fi

rpai mcp create --name "$MCP_NAME" --managed-config "$CONFIG_JSON" >/dev/null
ok "MCP '$MCP_NAME' ready: $AIGW_URL/mcp/v1/$MCP_NAME"
