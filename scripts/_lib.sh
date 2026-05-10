# Shared helpers. Source this from every step script.
# Conventions:
#   - All scripts require ENV=integration|production in the environment.
#   - All API calls go through curl; rpai is used for managed-MCP create/update.
#   - Idempotency: every step is safe to re-run.

set -euo pipefail

# --- env loading ---------------------------------------------------------

: "${ENV:?set ENV=integration or ENV=production}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ENV_FILE="$ROOT/env/${ENV}.env"
if [ ! -f "$ENV_FILE" ]; then
  echo "missing $ENV_FILE" >&2
  echo "run: cp env/${ENV}.env.example env/${ENV}.env && \$EDITOR env/${ENV}.env" >&2
  exit 1
fi
set -a; . "$ENV_FILE"; set +a

if [ -f "$ROOT/env/secrets.env" ]; then
  set -a; . "$ROOT/env/secrets.env"; set +a
fi

# RPAI_ENV is loaded from the env file. Non-empty → integration profile dir.
export RPAI_ENV

# --- pretty logging ------------------------------------------------------

c_blue=$'\033[34m'; c_yellow=$'\033[33m'; c_green=$'\033[32m'; c_red=$'\033[31m'; c_reset=$'\033[0m'
log()  { printf "%s[%s]%s %s\n" "$c_blue" "$ENV" "$c_reset" "$*"; }
warn() { printf "%s[%s]%s %s\n" "$c_yellow" "$ENV" "$c_reset" "$*" >&2; }
ok()   { printf "%s[%s ✓]%s %s\n" "$c_green" "$ENV" "$c_reset" "$*"; }
die()  { printf "%s[%s ✗]%s %s\n" "$c_red" "$ENV" "$c_reset" "$*" >&2; exit 1; }

# --- auth ----------------------------------------------------------------

require_token() {
  TOKEN="$(rpai auth token 2>/dev/null || true)"
  [ -n "${TOKEN:-}" ] || die "no rpai token. Run: RPAI_ENV=$RPAI_ENV rpai auth login"
  export TOKEN
}

# --- dataplane API helpers (cluster secrets, agents) ---------------------

# `_curl` is a status-aware wrapper. On 4xx/5xx it dumps the response and
# exits non-zero, which propagates via `set -e` into the calling script.
# All API helpers go through this so silent auth failures can't corrupt
# state (creating SERVICE_ACCOUNT_NULL etc.).
_curl() {
  local method="$1" url="$2" body="${3:-}"
  local tmp; tmp="$(mktemp)"
  local args=(-sS -o "$tmp" -w '%{http_code}' -X "$method" -H "Authorization: Bearer $TOKEN")
  case "$method" in POST|PUT|PATCH) args+=(-H "Content-Type: application/json"); esac
  case "$url" in *AIAgentService*) args+=(-H "Connect-Protocol-Version: 1");; esac
  [ -n "$body" ] && args+=(--data "$body")
  local code; code="$(curl "${args[@]}" "$url")"
  case "$code" in
    2*) cat "$tmp"; rm -f "$tmp" ;;
    *)  printf 'HTTP %s on %s %s\n%s\n' "$code" "$method" "$url" "$(cat "$tmp")" >&2
        rm -f "$tmp"; return 1 ;;
  esac
}

dp_get()  { _curl GET    "$DATAPLANE_API$1"; }
dp_post() { _curl POST   "$DATAPLANE_API$1" "$2"; }
dp_put()  { _curl PUT    "$DATAPLANE_API$1" "$2"; }
dp_del()  { _curl DELETE "$DATAPLANE_API$1"; }

# Connect-RPC against the dataplane (used for AIAgentService).
dp_rpc() { _curl POST "$DATAPLANE_API/$1" "$2"; }

# --- controlplane (IAM service accounts) ---------------------------------

cp_get()  { _curl GET    "$CONTROLPLANE_API$1"; }
cp_post() { _curl POST   "$CONTROLPLANE_API$1" "$2"; }
cp_del()  { _curl DELETE "$CONTROLPLANE_API$1"; }

# --- Salesforce MCP shortcuts via rpai ----------------------------------

# Run a SOQL query through the managed Salesforce MCP and emit the
# nested QueryResult JSON (totalSize / done / records).
sf_soql() {
  local soql="$1"
  rpai mcp tools call "$MCP_NAME" query --args "$(jq -nc --arg s "$soql" '{soql:$s}')" \
    | jq -r '.result' | jq .
}

# Create a Salesforce record. fields_json is a JSON string of the field map.
sf_create() {
  local sobject="$1" fields_json="$2"
  rpai mcp tools call "$MCP_NAME" create_record \
    --args "$(jq -nc --arg s "$sobject" --arg f "$fields_json" '{sobject:$s, fields:$f}')" \
    | jq -r '.record_id'
}

# --- misc ---------------------------------------------------------------

upper() { tr 'a-z' 'A-Z'; }
b64()   { printf '%s' "$1" | base64 | tr -d '\n'; }
