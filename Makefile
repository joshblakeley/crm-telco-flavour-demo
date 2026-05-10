.SHELLFLAGS := -eu -o pipefail -c
SHELL := /usr/bin/env bash

ENV ?= integration
export ENV

.DEFAULT_GOAL := help

help:
	@awk 'BEGIN{FS=":.*##"; printf "Usage: make <target> [ENV=integration|production]\n\nTargets:\n"} /^[a-zA-Z_-]+:.*##/ {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

up: secret mcp sa agent data ## Provision everything (secret, MCP, SA, agent, SF data)
	@echo "✓ stack up in env=$$ENV"

down: ## Tear everything down except Salesforce data
	@bash scripts/99-teardown.sh

secret: ## SF_CLIENT_SECRET cluster secret
	@bash scripts/01-secret.sh

mcp: secret ## Salesforce managed MCP
	@bash scripts/02-mcp.sh

sa: ## IAM service account + SERVICE_ACCOUNT_<ID> secret
	@bash scripts/03-service-account.sh

agent: sa mcp ## AIAgent (Telco CRM Agent)
	@bash scripts/04-agent.sh

data: mcp ## Load demo accounts/opps/cases into Salesforce dev org
	@bash scripts/05-sf-data.sh

status: ## Print state of provisioned resources
	@. scripts/_lib.sh; require_token; \
	echo "ENV=$$ENV  CLUSTER=$$CLUSTER_ID"; \
	echo; echo "--- aigw MCP ---"; rpai mcp get "$$MCP_NAME" 2>/dev/null || echo "(not present)"; \
	echo; echo "--- agent ---"; \
	dp_rpc redpanda.api.dataplane.v1alpha3.AIAgentService/ListAIAgents '{}' \
	  | jq -r --arg n "$$AGENT_DISPLAY_NAME" '.aiAgents[]? | select(.displayName == $$n) | "\(.id)\t\(.state)\t\(.url)"'

agent-id: ## Print the agent's URL (handy for curl-ing)
	@cat .state/$$ENV/agent_url 2>/dev/null || (. scripts/_lib.sh; require_token; \
	  dp_rpc redpanda.api.dataplane.v1alpha3.AIAgentService/ListAIAgents '{}' \
	    | jq -r --arg n "$$AGENT_DISPLAY_NAME" '.aiAgents[]? | select(.displayName == $$n) | .url')

smoke: ## Send a test prompt to the agent
	@. scripts/_lib.sh; require_token; \
	URL="$$(cat .state/$$ENV/agent_url 2>/dev/null)"; \
	[ -n "$$URL" ] || URL="$$(dp_rpc redpanda.api.dataplane.v1alpha3.AIAgentService/ListAIAgents '{}' | jq -r --arg n "$$AGENT_DISPLAY_NAME" '.aiAgents[]? | select(.displayName == $$n) | .url')"; \
	[ -n "$$URL" ] || { echo "no agent found"; exit 1; }; \
	echo "→ $$URL"; \
	curl -sS --max-time 90 -X POST "$$URL/" \
	  -H "Authorization: Bearer $$TOKEN" -H "Content-Type: application/json" \
	  -d '{"jsonrpc":"2.0","id":"smoke","method":"message/send","params":{"message":{"role":"user","parts":[{"kind":"text","text":"Status briefing on WindTre Business — open opps and cases. Bullets only."}],"messageId":"smoke-1"},"configuration":{"blocking":true}}}' \
	  > /tmp/smoke.json; \
	python3 -c 'import json,sys; j=json.load(open("/tmp/smoke.json")); [sys.stdout.write(p["text"]) for a in j.get("result",{}).get("artifacts",[]) for p in a.get("parts",[]) if p.get("kind")=="text"]; print(); print("--- state:", j.get("result",{}).get("status",{}).get("state"))'

stop-agent: ## Hit StopAIAgent (kill switch)
	@. scripts/_lib.sh; require_token; \
	AID="$$(cat .state/$$ENV/agent_id 2>/dev/null || dp_rpc redpanda.api.dataplane.v1alpha3.AIAgentService/ListAIAgents '{}' | jq -r --arg n "$$AGENT_DISPLAY_NAME" '.aiAgents[]? | select(.displayName == $$n) | .id')"; \
	[ -n "$$AID" ] || { echo "no agent"; exit 1; }; \
	dp_rpc redpanda.api.dataplane.v1alpha3.AIAgentService/StopAIAgent "$$(jq -nc --arg id "$$AID" '{id:$$id}')" | jq .

start-agent: ## Hit StartAIAgent
	@. scripts/_lib.sh; require_token; \
	AID="$$(cat .state/$$ENV/agent_id 2>/dev/null || dp_rpc redpanda.api.dataplane.v1alpha3.AIAgentService/ListAIAgents '{}' | jq -r --arg n "$$AGENT_DISPLAY_NAME" '.aiAgents[]? | select(.displayName == $$n) | .id')"; \
	[ -n "$$AID" ] || { echo "no agent"; exit 1; }; \
	dp_rpc redpanda.api.dataplane.v1alpha3.AIAgentService/StartAIAgent "$$(jq -nc --arg id "$$AID" '{id:$$id}')" | jq .

sf-clean: ## Delete demo Salesforce records (the SF dev org is shared!)
	@. scripts/_lib.sh; require_token; \
	echo "deleting demo accounts (cascade-deletes opps and cases)..."; \
	for n in "TIM Sparkle Italia" "WindTre Business" "Iliad Italia Wholesale" "Open Fiber S.p.A." "AWS EMEA Connectivity" "Sky Italia B2B"; do \
	  esc="$$(printf '%s' "$$n" | sed "s/'/\\\\'/g")"; \
	  ID="$$(rpai mcp tools call "$$MCP_NAME" query --args "$$(jq -nc --arg s "SELECT Id FROM Account WHERE Name = '$$esc' LIMIT 1" '{soql:$$s}')" | jq -r '.result' | jq -r '.records[0].Id // empty')"; \
	  [ -n "$$ID" ] || continue; \
	  echo "  $$n → $$ID"; \
	  rpai mcp tools call "$$MCP_NAME" delete_record --args "$$(jq -nc --arg s "Account" --arg i "$$ID" '{sobject:$$s, record_id:$$i}')" >/dev/null; \
	done

.PHONY: help up down secret mcp sa agent data status agent-id smoke stop-agent start-agent sf-clean
