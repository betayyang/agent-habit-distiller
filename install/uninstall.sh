#!/usr/bin/env bash
# Remove the scheduled jobs and the skill symlinks. Leaves your ledger,
# the habits blocks in CLAUDE.md / AGENTS.md, and config untouched.
#
# Usage: ./install/uninstall.sh [--agent claude|codex|both]   (default: both)

set -euo pipefail

AGENTS="claude codex"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent) [[ "$2" == both ]] && AGENTS="claude codex" || AGENTS="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

for AGENT in $AGENTS; do
  case "$AGENT" in
    claude) HOME_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; LABEL="com.claude.habit-distiller"; FILE=CLAUDE.md ;;
    codex)  HOME_DIR="${CODEX_HOME:-$HOME/.codex}"; LABEL="com.codex.habit-distiller"; FILE=AGENTS.md ;;
    *) echo "error: --agent must be claude, codex or both" >&2; exit 2 ;;
  esac
  SKILL_DST="$HOME_DIR/skills/distill-habits"

  case "$(uname -s)" in
    Darwin)
      PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
      if [[ -f "$PLIST_DST" ]]; then
        launchctl unload "$PLIST_DST" 2>/dev/null || true
        rm -f "$PLIST_DST"
        echo "[$AGENT] removed launchd job: $PLIST_DST"
      fi
      ;;
    Linux)
      PATTERN="habit-distiller ($AGENT)\|distill-habits/run.sh --agent $AGENT"
      # Pre-codex installs wrote an entry without --agent.
      [[ "$AGENT" == claude ]] && PATTERN="$PATTERN\|^# claude-habit-distiller$\|distill-habits/run.sh >>"
      if crontab -l 2>/dev/null | grep -q "$PATTERN"; then
        crontab -l 2>/dev/null | grep -v "$PATTERN" | crontab -
        echo "[$AGENT] removed cron entry"
      fi
      ;;
  esac

  if [[ -L "$SKILL_DST" ]]; then
    rm -f "$SKILL_DST"
    echo "[$AGENT] removed skill symlink: $SKILL_DST"
  fi
  echo "[$AGENT] to also wipe the habits block, delete the region between the"
  echo "  <!-- BEGIN habit-distiller --> ... <!-- END habit-distiller --> markers in $HOME_DIR/$FILE"
done

echo "done. Your ledger and habits blocks were left in place."
