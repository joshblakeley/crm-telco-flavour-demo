#!/usr/bin/env bash
# Idempotently create or update the AIAgent (v1alpha3) wired to the
# salesforce MCP and the cluster's Anthropic LLM provider.
#
# Subagent topology (read/write split, gateway-enforced via tool_filter_regex):
#
#   parent: Telco CRM Agent
#   ├─ crm_reader   → salesforce MCP, regex: ^(query|query_more|search|list_objects|describe_object|get_record)$
#   └─ crm_writer   → salesforce MCP, regex: ^(create_record|update_record|delete_record)$
#
# The parent's own salesforce MCP reference is also restricted to read-only
# so writes can ONLY happen via crm_writer dispatch (audit trail beat).

. "$(dirname "$0")/_lib.sh"
require_token

STATE_DIR="$ROOT/.state/$ENV"
SA_ID="$(cat "$STATE_DIR/sa_id" 2>/dev/null || true)"
[ -n "$SA_ID" ] || die "missing $STATE_DIR/sa_id; run 03-service-account.sh first"
SA_ID_UPPER="$(printf '%s' "$SA_ID" | upper)"

PARENT_PROMPT="$(cat "$ROOT/config/system-prompt.md")"
READER_PROMPT="$(cat "$ROOT/config/subagents/crm-reader.md")"
WRITER_PROMPT="$(cat "$ROOT/config/subagents/crm-writer.md")"

READ_REGEX='^(query|query_more|search|list_objects|describe_object|get_record)$'
WRITE_REGEX='^(create_record|update_record|delete_record)$'

# Find existing agent by displayName.
LIST="$(dp_rpc redpanda.api.dataplane.v1alpha3.AIAgentService/ListAIAgents '{}')"
AGENT_ID="$(echo "$LIST" | jq -r --arg n "$AGENT_DISPLAY_NAME" '.aiAgents[]? | select(.displayName == $n) | .id' | head -1)"

# Build the agent spec. We use __D__ as a placeholder for the literal
# `$` character in `${secrets...}` references — jq+bash quoting around a
# real `$` is a footgun, this sidesteps it.
SPEC_FIELDS="$(jq -nc \
  --arg dn "$AGENT_DISPLAY_NAME" \
  --arg desc "Customer-success agent reasoning over Salesforce CRM. Dispatches reads to crm_reader and writes to crm_writer (gateway-enforced split via tool_filter_regex)." \
  --arg model "$LLM_MODEL" \
  --arg sp "$PARENT_PROMPT" \
  --arg llm "$LLM_PROVIDER" \
  --arg mcp "$MCP_NAME" \
  --arg sa "$SA_ID_UPPER" \
  --arg env "$ENV" \
  --arg readre "$READ_REGEX" \
  --arg writere "$WRITE_REGEX" \
  --arg readsp "$READER_PROMPT" \
  --arg writesp "$WRITER_PROMPT" \
  '{
    displayName:$dn,
    description:$desc,
    model:$model,
    systemPrompt:$sp,
    provider:{anthropic:{}},
    gateway:{llmProvider:$llm},
    mcpServers:{($mcp):{id:$mcp, toolFilterRegex:$readre}},
    subagents:{
      crm_reader:{
        description:"Read-only Salesforce CRM lookups (accounts, opportunities, cases, schema). Use for any observational query.",
        systemPrompt:$readsp,
        mcpServers:{($mcp):{id:$mcp, toolFilterRegex:$readre}}
      },
      crm_writer:{
        description:"Salesforce mutations (create/update/delete records). Only call after gathering context via crm_reader and confirming with the user.",
        systemPrompt:$writesp,
        mcpServers:{($mcp):{id:$mcp, toolFilterRegex:$writere}}
      }
    },
    serviceAccount:{
      clientId:"__D__{secrets.SERVICE_ACCOUNT_\($sa).client_id}",
      clientSecret:"__D__{secrets.SERVICE_ACCOUNT_\($sa).client_secret}"
    },
    maxIterations:30,
    resources:{memoryShares:"400M", cpuShares:"100m"},
    tags:{demo:"telco", owner:"crm-telco-flavour-demo", env:$env}
  }' | sed 's/__D__/$/g')"

# UpdateAIAgent on v1alpha3 has a fiddly fieldmask format that varies by
# field (some accept top-level paths, some require the `ai_agent.` prefix,
# the `subagents` map needs special handling). Rather than fight it, if
# the agent already exists we delete + recreate. It's stateless config —
# brief downtime, but reliable and reproduces the same end state.
if [ -n "$AGENT_ID" ]; then
  log "agent '$AGENT_DISPLAY_NAME' exists ($AGENT_ID) — deleting then recreating to apply latest config"
  dp_rpc redpanda.api.dataplane.v1alpha3.AIAgentService/DeleteAIAgent "$(jq -nc --arg id "$AGENT_ID" '{id:$id}')" >/dev/null
fi

log "creating agent '$AGENT_DISPLAY_NAME'"
BODY="$(jq -nc --argjson f "$SPEC_FIELDS" '{aiAgent:$f}')"
RESP="$(dp_rpc redpanda.api.dataplane.v1alpha3.AIAgentService/CreateAIAgent "$BODY")"
AGENT_ID="$(echo "$RESP" | jq -r '.aiAgent.id')"

[ -n "$AGENT_ID" ] && [ "$AGENT_ID" != "null" ] || die "agent create failed: $RESP"
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
