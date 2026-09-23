#!/usr/bin/env bash
#
# Self-test for check-prod-env.py's bare-hostname rule.
#
#   Usage: scripts/check-prod-env.test.sh
#
# Runs the checker from /tmp on purpose: it used to read the compose file
# relative to the CURRENT directory, so the verdict depended on where you
# stood (and push-box-env.py runs it from the agentic-str checkout).
#
# READ THE SUMMARY LINE, not just the exit code.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/check-prod-env.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASSED=0
FAILED=0

# run <name> <env lines…> — sets OUT to the checker's output, run from /tmp.
run() {
  CASE="$1"; shift
  printf '%s\n' "$@" > "$WORK/case.env"
  OUT="$(cd /tmp && python3 "$CHECK" "$WORK/case.env" 2>&1)"
}
fails_on() { printf '%s\n' "$OUT" | grep -E "FAIL +$1" >/dev/null && PASSED=$((PASSED+1)) || { FAILED=$((FAILED+1)); echo "FAIL: $CASE — expected a FAIL for $1"; printf '%s\n' "$OUT" | sed 's/^/      | /'; }; }
no_fail_on() { printf '%s\n' "$OUT" | grep -E "FAIL +$1" >/dev/null && { FAILED=$((FAILED+1)); echo "FAIL: $CASE — unexpected FAIL for $1"; printf '%s\n' "$OUT" | sed 's/^/      | /'; } || PASSED=$((PASSED+1)); }
warns_on() { printf '%s\n' "$OUT" | grep -E "warn +$1" >/dev/null && PASSED=$((PASSED+1)) || { FAILED=$((FAILED+1)); echo "FAIL: $CASE — expected a warn for $1"; printf '%s\n' "$OUT" | sed 's/^/      | /'; }; }

# A flag whose NAME ends like a host key. `true` is a legal DNS label, which is
# how it was flagged as a bare hostname on the production box (2026-09-23).
run 'a boolean flag ending in _SERVER is not a host' 'ENABLE_PUSH_RELAY_SERVER=true'
no_fail_on 'ENABLE_PUSH_RELAY_SERVER'
run 'false / yes / 0 are not hosts either' 'A_SERVER=false' 'B_HOST=yes' 'C_ADDRESS=0'
no_fail_on 'A_SERVER'
no_fail_on 'B_HOST'
no_fail_on 'C_ADDRESS'

# The case the rule exists for must still fail.
run 'mailhog is still a bare hostname' 'SMTP_ADDRESS=mailhog'
fails_on 'SMTP_ADDRESS=mailhog'

# A service of the stack the BOX runs (docker-compose.prod.yaml) warns.
run 'a prod-stack service warns, from any cwd' 'SMTP_ADDRESS=redis'
warns_on 'SMTP_ADDRESS=redis'
no_fail_on 'SMTP_ADDRESS=redis'

# `postgres` is a service only in docker-compose.production.yaml. The box runs
# .prod.yaml (project mesh-crm-prod) with Neon, so on the box it resolves nowhere.
run 'postgres is not a service on the box' 'POSTGRES_HOST=postgres'
fails_on 'POSTGRES_HOST=postgres'

printf '\ncheck-prod-env self-test: %d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
