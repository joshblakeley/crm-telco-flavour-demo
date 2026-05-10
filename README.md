# crm-telco-flavour-demo

Repeatable scaffold for an ADP demo: a telco customer-success agent that
reasons over Salesforce CRM via a managed Salesforce MCP on Redpanda's
AI Gateway. Brings the whole stack up with `make up`.

## What gets provisioned (per cluster)

1. `SF_CLIENT_SECRET` cluster secret — the Salesforce Connected App's secret
2. `salesforce` managed MCP server (type `SalesforceMCP`) on aigw
3. IAM service account + `SERVICE_ACCOUNT_<ID>` cluster secret — the
   identity the agent runtime uses to talk to its own resources
4. `Telco CRM Agent` (AIAgent v1alpha3), wired to:
   - the cluster's Anthropic LLM provider
   - the `salesforce` MCP, with read-only `tool_filter_regex` on the
     parent's reference
   - two subagents:
     - `crm_reader` — read tools only (`query`, `query_more`, `search`,
       `list_objects`, `describe_object`, `get_record`)
     - `crm_writer` — write tools only (`create_record`, `update_record`,
       `delete_record`)
5. Six telco-flavoured Salesforce accounts + 12 opportunities + 9 cases
   in the shared SF dev org

## Subagent topology

```
parent: Telco CRM Agent
├─ crm_reader   salesforce MCP, regex: ^(query|query_more|search|list_objects|describe_object|get_record)$
└─ crm_writer   salesforce MCP, regex: ^(create_record|update_record|delete_record)$
```

The parent's system prompt requires every Salesforce interaction go
through one of the two subagents — `crm_reader` for any observation,
`crm_writer` only after the parent has gathered context, summarised the
proposed change, and obtained explicit user confirmation.

`tool_filter_regex` is enforced **server-side in aigw**, not at the
prompt layer — calls that don't match the regex are rejected before
they reach Salesforce.

## Prerequisites

- `rpai` (`brew install redpanda-data/tap/rpai`)
- `jq`, `curl`, `bash`, GNU `make`
- An Anthropic LLM provider already configured in aigw on the target
  cluster. The agent references it by name (`anthropic` for integration,
  `anthropic-api-key` for production by default — adjust in `env/*.env`
  if your cluster uses different names).
- Salesforce dev-org Connected App configured for `client_credentials`
  with a Run-As user

## Setup

```bash
# 1. Pick an env (integration or production)
export ENV=integration   # or: production

# 2. Drop the Salesforce client_secret into env/secrets.env (gitignored)
cp env/secrets.env.example env/secrets.env
$EDITOR env/secrets.env

# 3. Log in to rpai for the right env. The -p flag prevents the
#    "Already logged in to default profile" short-circuit when you
#    already have credentials in another rpai profile.
RPAI_ENV=integration rpai -p integration auth login    # integration
# rpai auth login                                      # production

# 4. Bring everything up
make up

# 5. Smoke-test the agent end-to-end
make smoke
```

`make up` is idempotent: every step (`secret`, `mcp`, `sa`, `agent`,
`data`) detects existing resources and either updates or skips. Safe to
re-run after editing `config/system-prompt.md`,
`config/subagents/*.md`, or `config/salesforce/*.tsv`.

## Daily ops

```bash
make status       # show MCP + agent state
make smoke        # ping the agent end-to-end
make agent-id     # print the agent URL (handy for curl-driven demos)
make stop-agent   # kill switch — StopAIAgent RPC
make start-agent  # bring it back up
```

## Demo flow (verified working)

```bash
# Read question — parent dispatches crm_reader
curl -X POST $AGENT_URL/ -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":"r","method":"message/send","params":{
    "message":{"role":"user",
      "parts":[{"kind":"text","text":"Status briefing on WindTre Business."}],
      "messageId":"r1"},
    "configuration":{"blocking":true}}}'

# Write request — parent dispatches crm_reader for context first,
# then asks for confirmation; on confirmation dispatches crm_writer.
# The agent narrates each dispatch in its response, giving a clear
# audit trail.
```

## Tear down

```bash
make down         # deletes agent, MCP, service account, cluster secrets
make sf-clean     # also deletes the seeded Salesforce records (dev org is shared!)
```

## Files

| | |
|---|---|
| `env/<env>.env`               | Cluster IDs, dataplane / aigw URLs, LLM provider name |
| `env/secrets.env`             | Salesforce client_secret (gitignored) |
| `config/system-prompt.md`     | Parent agent's dispatcher prompt |
| `config/subagents/crm-reader.md` | `crm_reader` subagent's system prompt |
| `config/subagents/crm-writer.md` | `crm_writer` subagent's system prompt |
| `config/salesforce/*.tsv`     | Demo accounts/opps/cases, keyed by Account name |
| `scripts/0[1-5]-*.sh`         | Idempotent provision steps; safe to re-run |
| `scripts/99-teardown.sh`      | Reverse the provisioning |
| `scripts/_lib.sh`             | rpai/curl helpers, env loader, status-aware curl wrapper |

## Notes

- The Salesforce dev org is **shared across envs** — the same SF records
  back both the production and integration agents. `make sf-clean` will
  affect both.
- `make agent` deletes and recreates the AIAgent on every run. The
  v1alpha3 `UpdateAIAgent` field-mask format varies by field and is
  finicky; a clean recreate is faster and reliable. Brief downtime, but
  the spec is stateless config so end state is identical.
- `make sa` cannot recover the IAM service account's `client_secret`
  after creation. If the matching `SERVICE_ACCOUNT_<ID>` cluster secret
  is missing for an existing SA, the script fails loudly and tells you
  to `make down && make up`.
