#!/usr/bin/env bash
# Idempotently create or update SF_CLIENT_SECRET on the cluster.
# Reads SF_CLIENT_SECRET from env/secrets.env.

. "$(dirname "$0")/_lib.sh"
require_token

[ -n "${SF_CLIENT_SECRET:-}" ] || die "SF_CLIENT_SECRET not set. Fill in env/secrets.env."

SCOPES='["SCOPE_REDPANDA_CONNECT","SCOPE_MCP_SERVER","SCOPE_AI_AGENT","SCOPE_AI_GATEWAY","SCOPE_REDPANDA_CLUSTER"]'
BODY="$(jq -nc --arg id "$SF_SECRET_NAME" --arg s "$(b64 "$SF_CLIENT_SECRET")" --argjson scopes "$SCOPES" \
  '{id:$id, secret_data:$s, scopes:$scopes, labels:{owner:"crm-telco-flavour-demo"}}')"

EXISTS="$(dp_get "/v1/secrets/$SF_SECRET_NAME" | jq -r '.secret.id // empty')"
if [ -n "$EXISTS" ]; then
  log "$SF_SECRET_NAME exists — updating value/scopes"
  dp_put "/v1/secrets/$SF_SECRET_NAME" "$BODY" | jq -r '.secret.id' >/dev/null
else
  log "$SF_SECRET_NAME does not exist — creating"
  dp_post "/v1/secrets" "$BODY" | jq -r '.secret.id' >/dev/null
fi
ok "secret $SF_SECRET_NAME present with scopes $SCOPES"
