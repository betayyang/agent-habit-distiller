#!/usr/bin/env bash
# Headless runner for the distill-habits skill.
# Called by the scheduled job (launchd / cron), or run manually for testing:
#   ./skills/distill-habits/run.sh                 # Claude Code (default)
#   ./skills/distill-habits/run.sh --agent codex   # Codex
#
# Env:
#   HABIT_DISTILLER_AGENT    default agent when --agent is not given (claude|codex)
#   HABIT_DISTILLER_WEBHOOK  optional URL; the run summary is POSTed as {"text": "..."}
#   CLAUDE_CONFIG_DIR        Claude home (default ~/.claude)
#   CODEX_HOME               Codex home (default ~/.codex)
#   CODEX_BIN                path to the codex CLI, if it is not on PATH

set -euo pipefail

AGENT="${HABIT_DISTILLER_AGENT:-claude}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent) AGENT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_MD="$SKILL_DIR/SKILL.md"

find_codex() {
  if [[ -n "${CODEX_BIN:-}" ]]; then echo "$CODEX_BIN"; return; fi
  command -v codex 2>/dev/null && return
  local c
  for c in /Applications/Codex.app/Contents/Resources/codex \
           /Applications/ChatGPT.app/Contents/Resources/codex; do
    [[ -x "$c" ]] && { echo "$c"; return; }
  done
  return 1
}

case "$AGENT" in
  claude)
    AGENT_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    INSTRUCTIONS="$AGENT_HOME/CLAUDE.md"
    command -v claude >/dev/null 2>&1 || {
      echo "error: 'claude' CLI not found on PATH" >&2; exit 127; }
    ;;
  codex)
    AGENT_HOME="${CODEX_HOME:-$HOME/.codex}"
    INSTRUCTIONS="$AGENT_HOME/AGENTS.md"
    CODEX="$(find_codex)" || {
      echo "error: 'codex' CLI not found (set CODEX_BIN)" >&2; exit 127; }
    ;;
  *) echo "error: --agent must be claude or codex" >&2; exit 2 ;;
esac

# Resolve the ledger the same way SKILL.md does, so logs and the Codex sandbox
# agree with the model. Python 3.9 has no tomllib, hence the regex fallback.
LEDGER="$(python3 - "$AGENT" "$AGENT_HOME" <<'PY'
import os, re, sys
agent, home = sys.argv[1], sys.argv[2]
paths = ["~/.config/habit-distiller/config.toml",
         "~/.config/claude-habit-distiller/config.toml", "./config.toml"]
cfg = next((os.path.expanduser(p) for p in paths if os.path.isfile(os.path.expanduser(p))), None)
val = None
if cfg:
    section = None
    for line in open(cfg, encoding="utf-8"):
        line = line.split("#", 1)[0].strip()
        m = re.match(r"^\[(\w+)\]$", line)
        if m:
            section = m.group(1); continue
        m = re.match(r'^memory_dir\s*=\s*"([^"]*)"', line)
        if m and section in (None, agent):
            if section == agent or val is None:
                val = m.group(1)
            if section == agent:
                break
if not val or val == "auto":
    val = os.path.join(home, "knowledge", "habits")
print(os.path.expanduser(val).rstrip("/"))
PY
)"
STATE_DIR="$LEDGER/.state/$AGENT"
mkdir -p "$STATE_DIR"

# Pre-codex installs kept run state in the skill dir. Move it once, here rather
# than in the prompt, so the window carries over exactly.
for f in last-run last-audit; do
  if [[ ! -f "$STATE_DIR/$f" && -f "$SKILL_DIR/.$f" ]]; then
    mv "$SKILL_DIR/.$f" "$STATE_DIR/$f"
  fi
done
LOG="$STATE_DIR/run.log"            # a few lines per run, appended
EXEC_LOG="$STATE_DIR/last-exec.log" # the agent's full output, overwritten each run
OUT="$STATE_DIR/last-summary.txt"

# Measure the habits block independently of what the model reports about itself.
# Characters, not bytes: `wc -c` overstates CJK by ~2.4x, and so does `wc -m`
# under launchd/cron, which start with no locale (C) and make it count bytes.
block_chars() {
  [[ -f "$INSTRUCTIONS" ]] || { echo 0; return; }
  awk '/^<!-- BEGIN habit-distiller/,/^<!-- END habit-distiller/' "$INSTRUCTIONS" \
    | python3 -c 'import sys; print(len(sys.stdin.buffer.read().decode("utf-8", "replace")))'
}

echo "===== $(date '+%Y-%m-%d %H:%M:%S') distill start (agent=$AGENT) =====" >>"$LOG"
BEFORE=$(block_chars)
echo "block chars (before): $BEFORE" >>"$LOG"

# SKILL.md is the single source of instructions. The "[habit-distiller run]"
# prefix lets the skill recognise (and skip) its own runs if they ever get logged.
PROMPT="[habit-distiller run] agent=${AGENT}. Read ${SKILL_MD} and follow its steps \
exactly for agent=${AGENT}: review conversations since the last run, distill my \
stable habits into the ledger, run one staleness audit pass, then update the habits \
block in ${INSTRUCTIONS} within its character budget, and finally update last-run \
and last-audit in ${STATE_DIR}. Hard constraints: (1) zero net growth -- the block \
must not be larger after the run than before; (2) evidence, cases, dates and \
numbers belong in the ledger, the block holds decision rules only; (3) this is a \
scheduled run, so never execute compact mode -- if the block is far over budget, \
warn instead of rewriting it wholesale; (4) any text removed from the block must \
land in a ledger file first; (5) block-size.tsv and run.log belong to this \
runner and the run report goes only in your final message -- do not write them, \
and do not create run or audit records in the ledger. Keep the report under 30 lines: agent, sessions \
scanned, ledger adds/updates/deletes, block characters (before -> after / limit) \
and whether zero net growth held, which entries were audited, and the strongest signal."

set +e
if [[ "$AGENT" == claude ]]; then
  # Unattended, so skip interactive permission prompts.
  claude -p "$PROMPT" --dangerously-skip-permissions >"$OUT" 2>"$EXEC_LOG"
  EXIT=$?
else
  # Sandboxed instead of bypassed: everything the run writes is under CODEX_HOME
  # (plus the ledger, if configured elsewhere). --ephemeral keeps this run out of
  # the sessions it will read tomorrow. stdin is closed or `codex exec` waits on it.
  ADD_DIR=()
  [[ "$LEDGER" == "$AGENT_HOME"/* ]] || ADD_DIR=(--add-dir "$LEDGER")
  "$CODEX" exec --ephemeral --skip-git-repo-check --color never \
    -C "$AGENT_HOME" -s workspace-write ${ADD_DIR[@]+"${ADD_DIR[@]}"} \
    -o "$OUT" "$PROMPT" </dev/null >"$EXEC_LOG" 2>&1
  EXIT=$?
fi
set -e

AFTER=$(block_chars)
DELTA=$((AFTER - BEFORE))
GROWTH=""
# The first run creates the block, so growth from 0 is expected.
[[ $BEFORE -gt 0 && $DELTA -gt 0 ]] && GROWTH="!! zero-net-growth violated: +$DELTA chars"
echo "block chars (after): $AFTER  delta=$DELTA  $GROWTH" >>"$LOG"
printf '%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%d')" "$BEFORE" "$AFTER" "$DELTA" \
  >>"$STATE_DIR/block-size.tsv"

# Optional webhook notification.
if [[ -n "${HABIT_DISTILLER_WEBHOOK:-}" ]]; then
  if [[ -s "$OUT" ]]; then TEXT="$(cat "$OUT")"; else
    TEXT="distill-habits finished (exit=$EXIT) but produced no report; see $EXEC_LOG"; fi
  STATUS="ok"; [[ $EXIT -ne 0 ]] && STATUS="FAILED exit=$EXIT"
  HEADER="habit-distiller[$AGENT] $STATUS $(date '+%Y-%m-%d %H:%M') | block ${BEFORE}->${AFTER} chars ${GROWTH}"
  # The URL stays in the environment: argv is visible to every local user via ps.
  python3 - "$HEADER" "$TEXT" >>"$LOG" 2>&1 <<'PY'
import json, os, sys, urllib.request
url = os.environ["HABIT_DISTILLER_WEBHOOK"]
header, text = sys.argv[1], sys.argv[2]
from urllib.parse import urlparse
msg = f"{header}\n\n{text}"
host = urlparse(url).hostname or ""
# Each service wants its own body; a generic {"text"} is rejected by Feishu/Lark
# and Discord.
if host.endswith(("feishu.cn", "larksuite.com", "larkoffice.com")):
    body = {"msg_type": "text", "content": {"text": msg}}
elif host.endswith(("discord.com", "discordapp.com")):
    body = {"content": msg[:2000]}
else:  # Slack and most generic webhooks
    body = {"text": msg}
req = urllib.request.Request(url, data=json.dumps(body).encode("utf-8"),
                             headers={"Content-Type": "application/json"})
try:
    resp = urllib.request.urlopen(req, timeout=15)
    print("webhook result:", resp.status, resp.read().decode("utf-8")[:300])
except Exception as e:
    print("webhook failed:", e)
PY
fi

echo "===== $(date '+%Y-%m-%d %H:%M:%S') distill end (exit=$EXIT) =====" >>"$LOG"
echo >>"$LOG"
exit "$EXIT"
