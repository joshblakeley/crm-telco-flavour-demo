# crm-telco-flavour-demo

Repeatable scaffold for an ADP demo: a "telco customer-success" agent that
reasons over Salesforce CRM via a managed Salesforce MCP on Redpanda's
AI Gateway.

What gets provisioned (per cluster):

1. `SF_CLIENT_SECRET` cluster secret — the Salesforce Connected App secret
2. `salesforce` MCP server (managed, type `SalesforceMCP`)
3. IAM service account + `SERVICE_ACCOUNT_<ID>` cluster secret — the
   identity the agent runtime uses to talk to its own resources
4. `Telco CRM Agent` (AIAgent v1alpha3) wired to `salesforce` MCP and the
   cluster's anthropic LLM provider
5. ~6 telco-flavoured Salesforce accounts + opportunities + cases in the
   shared dev org

## Prerequisites

- `rpai` (`brew install redpanda-data/tap/rpai`)
- `jq`, `curl`, `gnu-getopt` or BSD getopt
- Anthropic LLM provider already configured in aigw on the target cluster
  (the agent references it by name; default `anthropic` for integration,
  `anthropic-api-key` for production)
- Salesforce dev-org Connected App configured for client_credentials with
  a Run-As user

## Setup

```bash
# 1. Pick an env (integration or production). Each .env file pins the
#    cluster ID, dataplane URL, controlplane URL, and aigw LLM provider
#    name for that env.
export ENV=integration   # or: production

# 2. Drop the Salesforce client_secret into env/secrets.env (gitignored)
cp env/secrets.env.example env/secrets.env
$EDITOR env/secrets.env

# 3. Log in to rpai for the right env
RPAI_ENV=integration rpai auth login

# 4. Bring everything up
make up

# 5. Smoke test
make smoke
```

## Daily ops

```bash
make status       # show what exists
make smoke        # ping the agent end-to-end
make agent-id     # print the agent's UUID + URL
make logs         # not implemented; placeholder for future
```

## Tear down

```bash
make down         # deletes agent, MCP, service account, cluster secrets
                  # leaves Salesforce data in place (dev org is shared)
make sf-clean     # delete the demo Salesforce records
```

## Demo runbook (day-of)

A short cheatsheet with the kill-switch / rotate-secret beats:

- `make smoke` — agent answers a customer-status question
- `make stop-agent` — `StopAIAgent` RPC; pod terminates immediately
- `make start-agent` — bring it back up
- `make rotate-llm-key` — illustrate aigw secret rotation without touching
  the agent

## Files

| | |
|---|---|
| `env/<env>.env` | Cluster IDs, dataplane URL, aigw LLM provider name |
| `env/secrets.env` | Salesforce client_secret (gitignored) |
| `config/system-prompt.md` | Agent system prompt |
| `config/salesforce/*.tsv` | Demo accounts/opps/cases — keyed by Account name for lookup |
| `scripts/0[1-5]-*.sh` | Idempotent provision steps; safe to re-run |
| `scripts/99-teardown.sh` | Reverse the steps |
| `scripts/_lib.sh` | rpai/curl helpers, env loader |
