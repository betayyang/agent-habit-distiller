#!/usr/bin/env bash
# Headless runner for the distill-habits skill.
# Called by the scheduled job (launchd / cron), or run manually for testing:
#   ./skills/distill-habits/run.sh
#
# Optional: set HABIT_DISTILLER_WEBHOOK to a URL to POST the run summary
# (JSON {"text": "..."}) after each run. Leave unset to skip notification.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
LOG="$SKILL_DIR/run.log"
OUT="$SKILL_DIR/.last-summary.txt"
SKILL_MD="$SKILL_DIR/SKILL.md"

command -v claude >/dev/null 2>&1 || {
  echo "error: 'claude' CLI not found on PATH" >&2
  exit 127
}

# Measure the habits block independently of what the model reports about itself.
# Characters, not bytes: `wc -c` overstates CJK by ~2.4x.
CLAUDE_MD="$CLAUDE_HOME/CLAUDE.md"
block_chars() {
  [[ -f "$CLAUDE_MD" ]] || { echo 0; return; }
  awk '/^<!-- BEGIN habit-distiller/,/^<!-- END habit-distiller/' "$CLAUDE_MD" \
    | wc -m | tr -d ' '
}

echo "===== $(date '+%Y-%m-%d %H:%M:%S') distill start =====" >>"$LOG"
BEFORE=$(block_chars)
echo "block chars (before): $BEFORE" >>"$LOG"

# -p headless mode; SKILL.md is the single source of instructions.
# Unattended, so skip interactive permission prompts.
# claude's final report goes to OUT for optional notification.
PROMPT="Read ${SKILL_MD} and follow its steps exactly: review conversations since \
the last run, distill my stable habits into the ledger, run one staleness audit \
pass, then update the habits block in the global CLAUDE.md within its character \
budget, and finally update .last-run and .last-audit. Hard constraints: (1) zero \
net growth -- the block must not be larger after the run than before; (2) \
evidence, cases, dates and numbers belong in the ledger, the block holds decision \
rules only; (3) this is a scheduled run, so never execute compact mode -- if the \
block is far over budget, warn instead of rewriting it wholesale; (4) any text \
removed from the block must land in a ledger file first. Keep the report under 30 \
lines: sessions scanned, ledger adds/updates/deletes, block characters \
(before -> after / limit) and whether zero net growth held, which entries were \
audited, and the strongest signal."

set +e
claude -p "$PROMPT" --dangerously-skip-permissions >"$OUT" 2>>"$LOG"
EXIT=$?
set -e

AFTER=$(block_chars)
DELTA=$((AFTER - BEFORE))
GROWTH=""
[[ $DELTA -gt 0 ]] && GROWTH="!! zero-net-growth violated: +$DELTA chars"
echo "block chars (after): $AFTER  delta=$DELTA  $GROWTH" >>"$LOG"
printf '%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%d')" "$BEFORE" "$AFTER" "$DELTA" \
  >>"$SKILL_DIR/block-size.tsv"

# Optional webhook notification.
if [[ -n "${HABIT_DISTILLER_WEBHOOK:-}" ]]; then
  if [[ -s "$OUT" ]]; then TEXT="$(cat "$OUT")"; else
    TEXT="distill-habits finished (exit=$EXIT) but produced no report; see $LOG"; fi
  HEADER="habit-distiller $(date '+%Y-%m-%d %H:%M') | block ${BEFORE}->${AFTER} chars ${GROWTH}"
  python3 - "$HABIT_DISTILLER_WEBHOOK" "$HEADER" "$TEXT" >>"$LOG" 2>&1 <<'PY'
import json, sys, urllib.request
url, header, text = sys.argv[1], sys.argv[2], sys.argv[3]
payload = json.dumps({"text": f"{header}\n\n{text}"}).encode("utf-8")
req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
try:
    resp = urllib.request.urlopen(req, timeout=15)
    print("webhook result:", resp.read().decode("utf-8"))
except Exception as e:
    print("webhook failed:", e)
PY
fi

echo "===== $(date '+%Y-%m-%d %H:%M:%S') distill end (exit=$EXIT) =====" >>"$LOG"
echo >>"$LOG"
exit "$EXIT"
