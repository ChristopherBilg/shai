#!/bin/bash
# dependabot_worker/run.sh — fix a Dependabot alert and open a draft pull request
# Usage: workflows/dependabot_worker/run.sh <repo> <number>
# Reads: ANTHROPIC_API_KEY from environment; prompts/dependabot_worker.txt for LLM instructions
# Writes: draft GitHub pull request; ephemeral session log (prunable)
# Exit: 0 on success (including idempotent skip); 1 on failure; 2 on usage error
set -euo pipefail
# shellcheck source=lib/workflow.sh
source "$(dirname "$0")/../../lib/workflow.sh"

if [ "$#" -ne 2 ]; then
  printf 'Usage: workflows/dependabot_worker/run.sh <repo> <number>\n' >&2
  exit 2
fi

REPO="$1"
NUMBER="$2"

if [[ ! "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || [[ "$REPO" == *..* ]]; then
  printf 'error: repo must be OWNER/REPO format (got "%s")\n' "$REPO" >&2
  exit 2
fi

if [[ ! "$NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  printf 'error: alert number must be a positive integer (got "%s")\n' "$NUMBER" >&2
  exit 2
fi

wf_init

if wf_seen "dependabot:$REPO:$NUMBER"; then
  exit 0
fi

ALERT_JSON=$(gh api "repos/$REPO/dependabot/alerts/$NUMBER") ||
  wf_fail "cannot fetch Dependabot alert #$NUMBER on $REPO"

PACKAGE_NAME=$(printf '%s' "$ALERT_JSON" | jq -r '.dependency.package.name // ""')
ECOSYSTEM=$(printf '%s' "$ALERT_JSON" | jq -r '.dependency.package.ecosystem // ""')
MANIFEST_PATH=$(printf '%s' "$ALERT_JSON" | jq -r '.dependency.manifest_path // ""')
SEVERITY=$(printf '%s' "$ALERT_JSON" | jq -r '.security_vulnerability.severity // ""')
GHSA_ID=$(printf '%s' "$ALERT_JSON" | jq -r '.security_advisory.ghsa_id // ""')
CVE_ID=$(printf '%s' "$ALERT_JSON" | jq -r '.security_advisory.cve_id // ""')
ADVISORY_SUMMARY=$(printf '%s' "$ALERT_JSON" | jq -r '.security_advisory.summary // ""')
VULNERABLE_RANGE=$(printf '%s' "$ALERT_JSON" | jq -r '.security_vulnerability.vulnerable_version_range // ""')
PATCHED_VERSION=$(printf '%s' "$ALERT_JSON" | jq -r '.security_vulnerability.first_patched_version.identifier // ""')

if [ -z "$PATCHED_VERSION" ]; then
  wf_fail "no patched version available for Dependabot alert #$NUMBER on $REPO"
fi

CVE_DISPLAY=""
if [ -n "$CVE_ID" ]; then
  CVE_DISPLAY=" / $CVE_ID"
fi

SLUG=$(printf '%s' "$PACKAGE_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//' | cut -c1-50 | sed 's/-$//')
SLUG="${SLUG:-dependabot}"
BRANCH_NAME="shai/${NUMBER}-dependabot-${SLUG}"

ADVISORY_SUMMARY=$(printf '%s' "$ADVISORY_SUMMARY" | head -c 32000)

# shellcheck disable=SC2016
PACKAGE_NAME=$(printf '%s' "$PACKAGE_NAME" | jq -Rrs 'gsub("<\\s*/?\\s*external_data\\s*>?"; "[external_data]"; "i")')
# shellcheck disable=SC2016
ECOSYSTEM=$(printf '%s' "$ECOSYSTEM" | jq -Rrs 'gsub("<\\s*/?\\s*external_data\\s*>?"; "[external_data]"; "i")')
# shellcheck disable=SC2016
MANIFEST_PATH=$(printf '%s' "$MANIFEST_PATH" | jq -Rrs 'gsub("<\\s*/?\\s*external_data\\s*>?"; "[external_data]"; "i")')
# shellcheck disable=SC2016
GHSA_ID=$(printf '%s' "$GHSA_ID" | jq -Rrs 'gsub("<\\s*/?\\s*external_data\\s*>?"; "[external_data]"; "i")')
# shellcheck disable=SC2016
CVE_DISPLAY=$(printf '%s' "$CVE_DISPLAY" | jq -Rrs 'gsub("<\\s*/?\\s*external_data\\s*>?"; "[external_data]"; "i")')
# shellcheck disable=SC2016
ADVISORY_SUMMARY=$(printf '%s' "$ADVISORY_SUMMARY" | jq -Rrs 'gsub("<\\s*/?\\s*external_data\\s*>?"; "[external_data]"; "i")')
# shellcheck disable=SC2016
VULNERABLE_RANGE=$(printf '%s' "$VULNERABLE_RANGE" | jq -Rrs 'gsub("<\\s*/?\\s*external_data\\s*>?"; "[external_data]"; "i")')
# shellcheck disable=SC2016
PATCHED_VERSION=$(printf '%s' "$PATCHED_VERSION" | jq -Rrs 'gsub("<\\s*/?\\s*external_data\\s*>?"; "[external_data]"; "i")')

WF_POLICY="$(dirname "$0")/policy.json"
if [ -f "$WF_POLICY" ]; then
  export SHAI_POLICY_OVERLAY="$WF_POLICY"
fi

PROMPT_TEMPLATE=$("$DIR/shai-prompt" dependabot_worker) || wf_fail "cannot load prompts/dependabot_worker.txt"

PROMPT=$(printf '%s' "$PROMPT_TEMPLATE" |
  sed "s/{{NUMBER}}/$NUMBER/g" |
  sed "s|{{REPO}}|$REPO|g" |
  sed "s|{{BRANCH_NAME}}|$BRANCH_NAME|g")

PROMPT="${PROMPT//\{\{PACKAGE_NAME\}\}/$PACKAGE_NAME}"
PROMPT="${PROMPT//\{\{ECOSYSTEM\}\}/$ECOSYSTEM}"
PROMPT="${PROMPT//\{\{MANIFEST_PATH\}\}/$MANIFEST_PATH}"
PROMPT="${PROMPT//\{\{SEVERITY\}\}/$SEVERITY}"
PROMPT="${PROMPT//\{\{GHSA_ID\}\}/$GHSA_ID}"
PROMPT="${PROMPT//\{\{CVE_DISPLAY\}\}/$CVE_DISPLAY}"
PROMPT="${PROMPT//\{\{ADVISORY_SUMMARY\}\}/$ADVISORY_SUMMARY}"
PROMPT="${PROMPT//\{\{VULNERABLE_RANGE\}\}/$VULNERABLE_RANGE}"
PROMPT="${PROMPT//\{\{PATCHED_VERSION\}\}/$PATCHED_VERSION}"

RESULT=$(wf_llm --tools "$PROMPT") || wf_fail "pipeline error fixing Dependabot alert #$NUMBER"

TYPE=$(printf '%s' "$RESULT" | jq -r '.type // empty' 2>/dev/null) || TYPE=""
SOURCE=$(printf '%s' "$RESULT" | jq -r '.source // empty' 2>/dev/null) || SOURCE=""

if [ "$TYPE" = "message" ] && [ "$SOURCE" = "assistant" ]; then
  wf_mark "dependabot:$REPO:$NUMBER"
  wf_output "fixed Dependabot alert #$NUMBER on $REPO"
  exit 0
else
  wf_fail "unexpected response: type=$TYPE source=$SOURCE"
fi
