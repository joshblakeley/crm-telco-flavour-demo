#!/usr/bin/env bash
# Idempotently create or update the AIAgent (v1alpha3) wired to the
# salesforce MCP and the cluster's Anthropic LLM provider.

. "$(dirname "$0")/_lib.sh"
require_token

STATE_DIR="$ROOT/.state/$ENV"
SA_ID="$(cat "$STATE_DIR/sa_id" 2>/dev/null || true)"
[ -n "$SA_ID" ] || die "missing $STATE_DIR/sa_id; run 03-service-account.sh first"
SA_ID_UPPER="$(printf '%s' "$SA_ID" | upper)"

SYSTEM_PROMPT="$(cat "$ROOT/config/system-prompt.md")"

# Find existing agent by displayName.
LIST="$(dp_rpc redpanda.api.dataplane.v1alpha3.AIAgentService/ListAIAgents '{}')"
AGENT_ID="$(echo "$LIST" | jq -r --arg n "$AGENT_DISPLAY_NAME" '.aiAgents[]? | select(.displayName == $n) | .id' | head -1)"

# Build the agent spec. We use __D__ as a placeholder for the literal
# `$` character in `${secrets...}` references — jq+bash quoting around a
# real `$` is a footgun, this sidesteps it.
SPEC_FIELDS="$(jq -nc \
  --arg dn "$AGENT_DISPLAY_NAME" \
  --arg desc "Customer-success agent reasoning over Salesforce CRM via the salesforce MCP." \
  --arg model "$LLM_MODEL" \
  --arg sp "$SYSTEM_PROMPT" \
  --arg llm "$LLM_PROVIDER" \
  --arg mcp "$MCP_NAME" \
  --arg sa "$SA_ID_UPPER" \
  --arg env "$ENV" \
  '{
    displayName:$dn,
    description:$desc,
    model:$model,
    systemPrompt:$sp,
    provider:{anthropic:{}},
    gateway:{llmProvider:$llm},
    mcpServers:{($mcp):{id:$mcp}},
    serviceAccount:{
      clientId:"__D__{secrets.SERVICE_ACCOUNT_\($sa).client_id}",
      clientSecret:"__D__{secrets.SERVICE_ACCOUNT_\($sa).client_secret}"
    },
    maxIterations:30,
    resources:{memoryShares:"400M", cpuShares:"100m"},
    tags:{demo:"telco", owner:"crm-telco-flavour-demo", env:$env}
  }' | sed 's/__D__/$/g')"

if [ -n "$AGENT_ID" ]; then
  log "agent '$AGENT_DISPLAY_NAME' exists ($AGENT_ID) — updating"
  BODY="$(jq -nc --arg id "$AGENT_ID" --argjson f "$SPEC_FIELDS" \
    '{id:$id, aiAgent:$f, updateMask:"display_name,description,model,system_prompt,provider,gateway,mcp_servers,service_account,max_iterations,resources,tags"}')"
  RESP="$(dp_rpc redpanda.api.dataplane.v1alpha3.AIAgentService/UpdateAIAgent "$BODY")"
else
  log "creating agent '$AGENT_DISPLAY_NAME'"
  BODY="$(jq -nc --argjson f "$SPEC_FIELDS" '{aiAgent:$f}')"
  RESP="$(dp_rpc redpanda.api.dataplane.v1alpha3.AIAgentService/CreateAIAgent "$BODY")"
  AGENT_ID="$(echo "$RESP" | jq -r '.aiAgent.id')"
fi

[ -n "$AGENT_ID" ] && [ "$AGENT_ID" != "null" ] || die "agent create/update failed: $RESP"
echo "$AGENT_ID" > "$STATE_DIR/agent_id"

log "waiting for agent $AGENT_ID to reach RUNNING"
for i in $(seq 1 60); do
  STATE="$(dp_rpc redpanda.api.dataplane.v1alpha3.AIAgentService/GetAIAgent "$(jq -nc --arg id "$AGENT_ID" '{id:$id}')" | jq -r '.aiAgent.state // ""')"
  case "$STATE" in
    STATE_RUNNING) ok "agent RUNNING"; break ;;
    STATE_FAILED) die "agent FAILED" ;;
  esac
  sleep 5
done

URL="$(dp_rpc redpanda.api.dataplane.v1alpha3.AIAgentService/GetAIAgent "$(jq -nc --arg id "$AGENT_ID" '{id:$id}')" | jq -r '.aiAgent.url')"
echo "$URL" > "$STATE_DIR/agent_url"
ok "Agent ID: $AGENT_ID"
ok "Agent URL: $URL"
