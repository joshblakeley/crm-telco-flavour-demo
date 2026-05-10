#!/usr/bin/env bash
# Provision the IAM service account the agent runtime uses, and store
# its credentials as a cluster secret named SERVICE_ACCOUNT_<ID>.
#
# Idempotency caveat: IAM service-account secrets are only returned at
# create time, so once a SA exists we cannot recover its client_secret.
# Strategy:
#   - If a SA with name=$SA_NAME already exists in the resource group
#     AND a matching SERVICE_ACCOUNT_<ID> cluster secret exists,
#     reuse both and write the SA id to .state/sa_id.
#   - If the SA exists but the cluster secret is missing, fail loudly
#     and tell the operator to run teardown then up.

. "$(dirname "$0")/_lib.sh"
require_token

STATE_DIR="$ROOT/.state/$ENV"
mkdir -p "$STATE_DIR"

# Look up an existing SA by exact name. The IAM list endpoint paginates
# and `filter.name_contains` is unreliable here, so we walk all pages
# in the resource group and match locally.
SA_ID=""
PAGE_TOKEN=""
while :; do
  RESP="$(cp_get "/v1/service-accounts?filter.resource_group_id=$RESOURCE_GROUP_ID&page_size=200${PAGE_TOKEN:+&page_token=$PAGE_TOKEN}")"
  MATCH="$(echo "$RESP" | jq -r --arg n "$SA_NAME" '.service_accounts[]? | select(.name == $n) | .id' | head -1)"
  if [ -n "$MATCH" ]; then SA_ID="$MATCH"; break; fi
  PAGE_TOKEN="$(echo "$RESP" | jq -r '.next_page_token // ""')"
  [ -z "$PAGE_TOKEN" ] && break
done

if [ -n "$SA_ID" ]; then
  SA_ID_UPPER="$(printf '%s' "$SA_ID" | upper)"
  SECRET_NAME="SERVICE_ACCOUNT_${SA_ID_UPPER}"
  HAS_SECRET="$(dp_get "/v1/secrets/$SECRET_NAME" | jq -r '.secret.id // empty')"
  if [ -n "$HAS_SECRET" ]; then
    log "service account '$SA_NAME' ($SA_ID) and secret $SECRET_NAME already present — reusing"
    echo "$SA_ID" > "$STATE_DIR/sa_id"
    ok "SA: $SA_ID  Secret: $SECRET_NAME"
    exit 0
  fi
  die "SA '$SA_NAME' exists ($SA_ID) but cluster secret $SECRET_NAME is missing. Run 'make down' then 'make up'."
fi

log "creating service account '$SA_NAME' in resource group $RESOURCE_GROUP_ID"
SA_CREATE="$(cp_post "/v1/service-accounts" \
  "$(jq -nc --arg n "$SA_NAME" --arg d "Service account for the telco/Salesforce demo agent ($ENV)" --arg rg "$RESOURCE_GROUP_ID" \
    '{service_account:{name:$n, description:$d, resource_group_id:$rg}}')")"

SA_ID="$(echo "$SA_CREATE" | jq -r '.service_account.id')"
CLIENT_ID="$(echo "$SA_CREATE" | jq -r '.service_account.auth0_client_credentials.client_id')"
CLIENT_SECRET="$(echo "$SA_CREATE" | jq -r '.service_account.auth0_client_credentials.client_secret')"

[ -n "$SA_ID" ] && [ -n "$CLIENT_ID" ] && [ -n "$CLIENT_SECRET" ] || die "service account creation failed: $SA_CREATE"

SA_ID_UPPER="$(printf '%s' "$SA_ID" | upper)"
SECRET_NAME="SERVICE_ACCOUNT_${SA_ID_UPPER}"
JSON_VALUE="$(jq -nc --arg c "$CLIENT_ID" --arg s "$CLIENT_SECRET" '{client_id:$c, client_secret:$s}')"

log "storing $SECRET_NAME as cluster secret"
dp_post "/v1/secrets" "$(jq -nc --arg id "$SECRET_NAME" --arg s "$(b64 "$JSON_VALUE")" --arg said "$SA_ID" \
  '{id:$id, secret_data:$s,
    scopes:["SCOPE_REDPANDA_CONNECT","SCOPE_AI_AGENT","SCOPE_AI_GATEWAY"],
    labels:{owner:"crm-telco-flavour-demo", service_account_id:$said}}')" >/dev/null

echo "$SA_ID" > "$STATE_DIR/sa_id"
ok "SA: $SA_ID  Secret: $SECRET_NAME"
