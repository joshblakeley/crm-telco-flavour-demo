#!/usr/bin/env bash
# Idempotently load demo accounts/opps/cases into the Salesforce dev org.
#
# Strategy: lookup-by-name. If a record with the target Name (or
# Account+Subject for Cases) already exists, skip. Otherwise create.
# This means the dev org is shared across envs and the data is loaded
# at most once.

. "$(dirname "$0")/_lib.sh"
require_token

ACCOUNTS_TSV="$ROOT/config/salesforce/accounts.tsv"
OPPS_TSV="$ROOT/config/salesforce/opportunities.tsv"
CASES_TSV="$ROOT/config/salesforce/cases.tsv"

# Helper: look up Account.Id by Name (returns empty if not found).
acct_id_by_name() {
  local name="$1"
  local soql="SELECT Id FROM Account WHERE Name = '$(printf '%s' "$name" | sed "s/'/\\\\'/g")' LIMIT 1"
  sf_soql "$soql" | jq -r '.records[0].Id // empty'
}

# --- accounts -----------------------------------------------------------

log "loading accounts"
{
  IFS=$'\t' read -r -a HEADERS  # discard header
  while IFS=$'\t' read -r name desc industry type phone web country revenue employees; do
    [ -z "$name" ] && continue
    EXISTING="$(acct_id_by_name "$name")"
    if [ -n "$EXISTING" ]; then
      log "  [exists] $name → $EXISTING"
      continue
    fi
    FIELDS="$(jq -nc \
      --arg n "$name" --arg d "$desc" --arg i "$industry" --arg t "$type" \
      --arg p "$phone" --arg w "$web" --arg c "$country" \
      --argjson r "${revenue:-0}" --argjson e "${employees:-0}" \
      '{Name:$n, Description:$d, Industry:$i, Type:$t, Phone:$p, Website:$w, BillingCountry:$c, AnnualRevenue:$r, NumberOfEmployees:$e}')"
    NEW_ID="$(sf_create Account "$FIELDS")"
    log "  [created] $name → $NEW_ID"
  done
} < "$ACCOUNTS_TSV"

# --- opportunities ------------------------------------------------------

log "loading opportunities"
{
  IFS=$'\t' read -r -a HEADERS  # discard header
  while IFS=$'\t' read -r acct_name name amount stage close_date desc; do
    [ -z "$acct_name" ] && continue
    AID="$(acct_id_by_name "$acct_name")"
    [ -n "$AID" ] || { warn "  [skip] no account for $acct_name → $name"; continue; }
    SOQL="SELECT Id FROM Opportunity WHERE AccountId = '$AID' AND Name = '$(printf '%s' "$name" | sed "s/'/\\\\'/g")' LIMIT 1"
    EXISTING="$(sf_soql "$SOQL" | jq -r '.records[0].Id // empty')"
    if [ -n "$EXISTING" ]; then
      log "  [exists] $name → $EXISTING"
      continue
    fi
    FIELDS="$(jq -nc --arg n "$name" --arg ai "$AID" --argjson a "${amount:-0}" \
                     --arg s "$stage" --arg c "$close_date" --arg d "$desc" \
      '{Name:$n, AccountId:$ai, Amount:$a, StageName:$s, CloseDate:$c, Description:$d, Type:"New Customer"}')"
    NEW_ID="$(sf_create Opportunity "$FIELDS")"
    log "  [created] $name → $NEW_ID"
  done
} < "$OPPS_TSV"

# --- cases --------------------------------------------------------------

log "loading cases"
{
  IFS=$'\t' read -r -a HEADERS  # discard header
  while IFS=$'\t' read -r acct_name subject priority stat origin type desc; do
    [ -z "$acct_name" ] && continue
    AID="$(acct_id_by_name "$acct_name")"
    [ -n "$AID" ] || { warn "  [skip] no account for $acct_name → $subject"; continue; }
    SOQL="SELECT Id FROM Case WHERE AccountId = '$AID' AND Subject = '$(printf '%s' "$subject" | sed "s/'/\\\\'/g")' LIMIT 1"
    EXISTING="$(sf_soql "$SOQL" | jq -r '.records[0].Id // empty')"
    if [ -n "$EXISTING" ]; then
      log "  [exists] $subject → $EXISTING"
      continue
    fi
    FIELDS="$(jq -nc --arg ai "$AID" --arg s "$subject" --arg p "$priority" \
                     --arg st "$stat" --arg o "$origin" --arg t "$type" --arg d "$desc" \
      '{AccountId:$ai, Subject:$s, Priority:$p, Status:$st, Origin:$o, Type:$t, Description:$d}')"
    NEW_ID="$(sf_create Case "$FIELDS")"
    log "  [created] $subject → $NEW_ID"
  done
} < "$CASES_TSV"

ok "Salesforce data loaded"
