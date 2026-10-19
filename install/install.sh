#!/usr/bin/env bash
# Install agent-habit-distiller for Claude Code and/or Codex:
#   1. link the skill into ~/.claude/skills/ and/or ~/.codex/skills/
#   2. schedule a daily run per agent via launchd (macOS) or cron (Linux)
#
# Usage:
#   ./install/install.sh [--agent claude|codex|both] [--hour H] [--minute M] [--no-schedule]
#
# Without --agent, every agent whose CLI is found gets installed.
# With --hour/--minute both agents run at that time; by default Codex runs
# 30 minutes after Claude so two runs never write a shared ledger at once.
#
# Env:
#   CLAUDE_CONFIG_DIR   Claude home (default: ~/.claude)
#   CODEX_HOME          Codex home (default: ~/.codex)
#   CODEX_BIN           path to the codex CLI, if it is not on PATH
#   HABIT_DISTILLER_WEBHOOK  if set, baked into the scheduled job so each run
#                            (failed ones included) posts its summary there

set -euo pipefail

AGENTS=""
HOUR=21
MINUTE=17
TIME_SET=0
SCHEDULE=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)  AGENTS="$2"; shift 2 ;;
    --hour)   HOUR="$2"; TIME_SET=1; shift 2 ;;
    --minute) MINUTE="$2"; TIME_SET=1; shift 2 ;;
    --no-schedule) SCHEDULE=0; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_SRC="$REPO_DIR/skills/distill-habits"
RUN_SH="$SKILL_SRC/run.sh"

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

case "$AGENTS" in
  "")
    command -v claude >/dev/null 2>&1 && AGENTS="claude"
    find_codex >/dev/null && AGENTS="${AGENTS:+$AGENTS }codex"
    [[ -n "$AGENTS" ]] || {
      echo "error: neither 'claude' nor 'codex' CLI found. Install one first." >&2; exit 127; }
    ;;
  both) AGENTS="claude codex" ;;
  claude|codex) ;;
  *) echo "error: --agent must be claude, codex or both" >&2; exit 2 ;;
esac

# Seed a user config if none exists.
CONF_DIR="$HOME/.config/habit-distiller"
if [[ ! -f "$CONF_DIR/config.toml" && ! -f "$HOME/.config/claude-habit-distiller/config.toml" \
      && ! -f "$REPO_DIR/config.toml" ]]; then
  mkdir -p "$CONF_DIR"
  cp "$REPO_DIR/config.example.toml" "$CONF_DIR/config.toml"
  echo "seeded config: $CONF_DIR/config.toml (edit to taste)"
fi
chmod +x "$RUN_SH"

for AGENT in $AGENTS; do
  case "$AGENT" in
    claude)
      command -v claude >/dev/null 2>&1 || {
        echo "error: 'claude' CLI not found on PATH. Install Claude Code first." >&2; exit 127; }
      SKILLS_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills"
      BIN_DIR="$(dirname "$(command -v claude)")"
      LABEL="com.claude.habit-distiller"
      A_HOUR=$HOUR; A_MINUTE=$MINUTE
      ;;
    codex)
      CODEX="$(find_codex)" || {
        echo "error: 'codex' CLI not found. Install Codex or set CODEX_BIN." >&2; exit 127; }
      SKILLS_DIR="${CODEX_HOME:-$HOME/.codex}/skills"
      BIN_DIR="$(dirname "$CODEX")"
      LABEL="com.codex.habit-distiller"
      if [[ $TIME_SET -eq 1 ]]; then A_HOUR=$HOUR; A_MINUTE=$MINUTE; else
        T=$(( (HOUR * 60 + MINUTE + 30) % 1440 )); A_HOUR=$((T / 60)); A_MINUTE=$((T % 60)); fi
      ;;
  esac

  # 1. Link the skill into the agent's skills dir.
  SKILL_DST="$SKILLS_DIR/distill-habits"
  mkdir -p "$SKILLS_DIR"
  if [[ -e "$SKILL_DST" && ! -L "$SKILL_DST" ]]; then
    echo "error: $SKILL_DST exists and is not a symlink; move it aside first." >&2
    exit 1
  fi
  ln -sfn "$SKILL_SRC" "$SKILL_DST"
  echo "[$AGENT] linked skill: $SKILL_DST -> $SKILL_SRC"

  if [[ "$SCHEDULE" -eq 0 ]]; then
    echo "[$AGENT] scheduling skipped; run manually: $RUN_SH --agent $AGENT"
    continue
  fi

  # 2. Schedule the daily run.
  BIN_PATH="$BIN_DIR:/usr/local/bin:/usr/bin:/bin"
  render() {
    sed -e "s|__RUN_SH__|$RUN_SH|g" \
        -e "s|__AGENT__|$AGENT|g" \
        -e "s|__LABEL__|$LABEL|g" \
        -e "s|__HOUR__|$A_HOUR|g" \
        -e "s|__MINUTE__|$A_MINUTE|g" \
        -e "s|__PATH__|$BIN_PATH|g" \
        -e "s|__SKILL_DIR__|$SKILL_SRC|g" "$1"
  }
  case "$(uname -s)" in
    Darwin)
      PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
      render "$REPO_DIR/install/habit-distiller.plist.tpl" >"$PLIST_DST"
      if [[ -n "${HABIT_DISTILLER_WEBHOOK:-}" ]]; then
        /usr/libexec/PlistBuddy -c \
          "Add :EnvironmentVariables:HABIT_DISTILLER_WEBHOOK string $HABIT_DISTILLER_WEBHOOK" "$PLIST_DST"
        chmod 600 "$PLIST_DST"   # the webhook URL is a credential
        echo "[$AGENT] webhook notification enabled"
      fi
      launchctl unload "$PLIST_DST" 2>/dev/null || true
      launchctl load "$PLIST_DST"
      echo "[$AGENT] scheduled via launchd at $A_HOUR:$(printf '%02d' "$A_MINUTE") daily -> $PLIST_DST"
      ;;
    Linux)
      LINE="$(render "$REPO_DIR/install/crontab.tpl" | grep -v '^#')"
      [[ -n "${HABIT_DISTILLER_WEBHOOK:-}" ]] && \
        LINE="${LINE/PATH=/HABIT_DISTILLER_WEBHOOK=$HABIT_DISTILLER_WEBHOOK PATH=}"
      # Drop this agent's previous entry (and, for claude, the pre-codex one without --agent).
      ( crontab -l 2>/dev/null \
          | grep -v "habit-distiller ($AGENT)\|distill-habits/run.sh --agent $AGENT" \
          | { [[ "$AGENT" == claude ]] \
                && grep -v '^# claude-habit-distiller$\|distill-habits/run.sh >>' || cat; } \
          || true; \
        echo "# habit-distiller ($AGENT)"; echo "$LINE" ) | crontab -
      echo "[$AGENT] scheduled via cron at $A_HOUR:$(printf '%02d' "$A_MINUTE") daily"
      ;;
    *)
      echo "[$AGENT] unsupported OS for auto-scheduling; run manually: $RUN_SH --agent $AGENT" >&2
      ;;
  esac
done

echo "done. Test now with: $RUN_SH --agent <claude|codex>"
